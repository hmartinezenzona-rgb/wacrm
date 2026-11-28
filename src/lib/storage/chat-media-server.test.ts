import { beforeEach, describe, expect, it, vi } from 'vitest';

const download = vi.fn();
const createSignedUrl = vi.fn();
const createSignedUrls = vi.fn();
const from = vi.fn(() => ({ download, createSignedUrl, createSignedUrls }));
vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({ storage: { from } }),
}));

import { downloadChatMedia, signChatMediaUrl, signChatMediaUrls } from './chat-media-server';

const OTHER = '9a8b7c6d-1111-4222-8333-444455556666';
const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
const PATH = `account-${ACCT}/1700000000000-wa-123.jpg`;
const PUBLIC = `https://abc.supabase.co/storage/v1/object/public/chat-media/${PATH}`;

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe('downloadChatMedia', () => {
  it('downloads from the chat-media bucket with the service role', async () => {
    download.mockResolvedValue({
      data: new Blob([new Uint8Array([1, 2, 3])], { type: 'image/jpeg' }),
      error: null,
    });
    const out = await downloadChatMedia(PATH, ACCT);
    expect(from).toHaveBeenCalledWith('chat-media');
    expect(download).toHaveBeenCalledWith(PATH);
    expect(out?.contentType).toBe('image/jpeg');
    expect(new Uint8Array(out!.bytes)).toEqual(new Uint8Array([1, 2, 3]));
  });

  it('returns null when the object is missing', async () => {
    download.mockResolvedValue({ data: null, error: { message: 'Object not found' } });
    expect(await downloadChatMedia(PATH, ACCT)).toBeNull();
  });

  it('falls back to octet-stream when the blob has no type', async () => {
    download.mockResolvedValue({ data: new Blob([new Uint8Array([1])]), error: null });
    expect((await downloadChatMedia(PATH, ACCT))?.contentType).toBe('application/octet-stream');
  });
});

describe('signChatMediaUrl', () => {
  it('signs a chat-media URL for the requested lifetime', async () => {
    createSignedUrl.mockResolvedValue({
      data: { signedUrl: 'https://abc.supabase.co/storage/v1/object/sign/chat-media/x?token=t' },
      error: null,
    });
    const out = await signChatMediaUrl(PUBLIC, 3600, ACCT);
    expect(createSignedUrl).toHaveBeenCalledWith(PATH, 3600);
    expect(out).toBe('https://abc.supabase.co/storage/v1/object/sign/chat-media/x?token=t');
  });

  it('returns other URLs and nullish values unchanged without touching storage', async () => {
    expect(await signChatMediaUrl('https://example.com/a.png', 60, ACCT)).toBe('https://example.com/a.png');
    expect(await signChatMediaUrl(null, 60, ACCT)).toBeNull();
    expect(createSignedUrl).not.toHaveBeenCalled();
  });

  it('falls back to the original URL when signing fails', async () => {
    createSignedUrl.mockResolvedValue({ data: null, error: { message: 'boom' } });
    expect(await signChatMediaUrl(PUBLIC, 60, ACCT)).toBe(PUBLIC);
  });
});

describe('account scoping', () => {
  it("refuses to download another account's object", async () => {
    await expect(downloadChatMedia(PATH, OTHER)).rejects.toThrow(/another account/);
    expect(download).not.toHaveBeenCalled();
  });

  it("refuses to sign another account's object", async () => {
    await expect(signChatMediaUrl(PUBLIC, 60, OTHER)).rejects.toThrow(/another account/);
    expect(createSignedUrl).not.toHaveBeenCalled();
  });
});

const PROXY = `/api/chat-media/${PATH}`;

describe('signChatMediaUrls', () => {
  it('dedupes paths and signs the batch once with the 3,600 s TTL', async () => {
    createSignedUrls.mockResolvedValue({
      data: [{ path: PATH, signedUrl: 'https://signed/1', error: null }],
      error: null,
    });

    const result = await signChatMediaUrls([PUBLIC, PROXY, PUBLIC], ACCT);

    expect(from).toHaveBeenCalledWith('chat-media');
    expect(createSignedUrls).toHaveBeenCalledTimes(1);
    expect(createSignedUrls).toHaveBeenCalledWith([PATH], 3600);
    expect(result.signed).toEqual({ [PUBLIC]: 'https://signed/1', [PROXY]: 'https://signed/1' });
    expect(result.expiresIn).toBe(3600);
    expect(result.ok).toBe(true);
  });

  it('honours an explicit TTL', async () => {
    createSignedUrls.mockResolvedValue({
      data: [{ path: PATH, signedUrl: 'https://signed/1', error: null }],
      error: null,
    });
    const result = await signChatMediaUrls([PUBLIC], ACCT, 60);
    expect(createSignedUrls).toHaveBeenCalledWith([PATH], 60);
    expect(result.expiresIn).toBe(60);
  });

  it("never signs another account's object and never touches Storage", async () => {
    const foreign = `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${OTHER}/x.jpg`;
    const result = await signChatMediaUrls([foreign], ACCT);
    expect(result.signed).toEqual({});
    expect(createSignedUrls).not.toHaveBeenCalled();
    expect(result.ok).toBe(true);
  });

  it('skips non chat-media URLs', async () => {
    const result = await signChatMediaUrls(['https://example.com/x.png'], ACCT);
    expect(result.signed).toEqual({});
    expect(createSignedUrls).not.toHaveBeenCalled();
  });

  it('reports a signing failure without throwing', async () => {
    createSignedUrls.mockResolvedValue({ data: null, error: { message: 'boom' } });
    const result = await signChatMediaUrls([PUBLIC], ACCT);
    expect(result.signed).toEqual({});
    expect(result.expiresIn).toBe(3600);
    expect(result.ok).toBe(false);
    expect(console.error).toHaveBeenCalled();
  });

  it('maps a per-row failure to no entry but keeps the rest', async () => {
    createSignedUrls.mockResolvedValue({
      data: [
        { path: PATH, signedUrl: 'https://signed/1', error: null },
        { path: `account-${ACCT}/broken.jpg`, signedUrl: null, error: 'not found' },
      ],
      error: null,
    });
    const broken = `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${ACCT}/broken.jpg`;
    const result = await signChatMediaUrls([PUBLIC, broken], ACCT);
    expect(result.signed).toEqual({ [PUBLIC]: 'https://signed/1' });
  });
});
