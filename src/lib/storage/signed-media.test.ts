import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { resetSignedMediaCache, resolveMediaSrc } from './signed-media';
import {
  invalidateSignedMedia,
  peekSignedMediaSrc,
  seedSignedMedia,
} from './signed-media';

const ACCOUNT = 'account-465fb4ce-33b6-4473-ad2c-42818772f587';
const A = `https://x.supabase.co/storage/v1/object/public/chat-media/${ACCOUNT}/a.jpg`;
const B = `https://x.supabase.co/storage/v1/object/public/chat-media/${ACCOUNT}/b.jpg`;

function jsonResponse(body: unknown, ok = true) {
  return Promise.resolve({
    ok,
    json: () => Promise.resolve(body),
  } as Response);
}

beforeEach(() => {
  resetSignedMediaCache();
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  resetSignedMediaCache();
});

describe('resolveMediaSrc', () => {
  it('firma en lote: dos imágenes montadas juntas hacen una sola petición', async () => {
    const fetchMock = vi.fn().mockImplementation(() =>
      jsonResponse({ signed: { [A]: 'https://signed/a', [B]: 'https://signed/b' }, expiresIn: 3600 }),
    );
    vi.stubGlobal('fetch', fetchMock);

    const first = resolveMediaSrc(A);
    const second = resolveMediaSrc(B);
    await vi.advanceTimersByTimeAsync(50);

    await expect(first).resolves.toBe('https://signed/a');
    await expect(second).resolves.toBe('https://signed/b');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string).urls.sort())
      .toEqual([A, B].sort());
  });

  it('reutiliza la URL firmada mientras no expira', async () => {
    const fetchMock = vi.fn().mockImplementation(() =>
      jsonResponse({ signed: { [A]: 'https://signed/a' }, expiresIn: 3600 }),
    );
    vi.stubGlobal('fetch', fetchMock);

    const first = resolveMediaSrc(A);
    await vi.advanceTimersByTimeAsync(50);
    await expect(first).resolves.toBe('https://signed/a');

    await expect(resolveMediaSrc(A)).resolves.toBe('https://signed/a');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('si firmar falla, devuelve el proxy de siempre', async () => {
    vi.stubGlobal('fetch', vi.fn().mockImplementation(() => jsonResponse({ error: 'boom' }, false)));

    const result = resolveMediaSrc(A);
    await vi.advanceTimersByTimeAsync(50);

    await expect(result).resolves.toBe(`/api/chat-media/${ACCOUNT}/a.jpg`);
  });

  it('una URL que no es chat-media se devuelve tal cual, sin red', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);

    await expect(resolveMediaSrc('https://example.com/x.jpg')).resolves.toBe('https://example.com/x.jpg');
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('seedSignedMedia / peekSignedMediaSrc / invalidateSignedMedia', () => {
  it('returns a seeded URL synchronously on the peek', () => {
    seedSignedMedia({ [A]: 'https://signed/a' }, 3600);
    expect(peekSignedMediaSrc(A)).toBe('https://signed/a');
  });

  it('expires from the receive time plus the server lifetime', () => {
    const receivedAt = Date.now();
    seedSignedMedia({ [A]: 'https://signed/a' }, 3600, receivedAt);
    expect(peekSignedMediaSrc(A)).toBe('https://signed/a');
    // Inside the existing 5-minute refresh margin, so the peek refuses it.
    vi.advanceTimersByTime((3600 - 300) * 1000 + 1);
    expect(peekSignedMediaSrc(A)).toBeNull();
  });

  it('does not hand out an expired entry', () => {
    seedSignedMedia({ [A]: 'https://signed/a' }, 600);
    vi.advanceTimersByTime(601_000);
    expect(peekSignedMediaSrc(A)).toBeNull();
  });

  it('ignores non chat-media keys and nullish input', () => {
    seedSignedMedia({ 'https://example.com/x.jpg': 'https://signed/x' }, 3600);
    expect(peekSignedMediaSrc('https://example.com/x.jpg')).toBeNull();
    expect(peekSignedMediaSrc(null)).toBeNull();
    expect(peekSignedMediaSrc(undefined)).toBeNull();
  });

  it('resolveMediaSrc uses a fresh seeded URL without signing again', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    seedSignedMedia({ [A]: 'https://signed/a' }, 3600);

    await expect(resolveMediaSrc(A)).resolves.toBe('https://signed/a');
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('invalidateSignedMedia forces a re-sign', async () => {
    const fetchMock = vi.fn().mockImplementation(() =>
      jsonResponse({ signed: { [A]: 'https://signed/a2' }, expiresIn: 3600 }),
    );
    vi.stubGlobal('fetch', fetchMock);
    seedSignedMedia({ [A]: 'https://signed/a' }, 3600);

    invalidateSignedMedia(A);
    expect(peekSignedMediaSrc(A)).toBeNull();

    const result = resolveMediaSrc(A);
    await vi.advanceTimersByTimeAsync(50);
    await expect(result).resolves.toBe('https://signed/a2');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
