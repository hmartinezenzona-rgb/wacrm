import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { resetSignedMediaCache, resolveMediaSrc } from './signed-media';

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
