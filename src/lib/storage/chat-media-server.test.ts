import { beforeEach, describe, expect, it, vi } from 'vitest';

const download = vi.fn();
const createSignedUrl = vi.fn();
const from = vi.fn(() => ({ download, createSignedUrl }));
vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({ storage: { from } }),
}));

import { downloadChatMedia, signChatMediaUrl } from './chat-media-server';

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
    const out = await downloadChatMedia(PATH);
    expect(from).toHaveBeenCalledWith('chat-media');
    expect(download).toHaveBeenCalledWith(PATH);
    expect(out?.contentType).toBe('image/jpeg');
    expect(new Uint8Array(out!.bytes)).toEqual(new Uint8Array([1, 2, 3]));
  });

  it('returns null when the object is missing', async () => {
    download.mockResolvedValue({ data: null, error: { message: 'Object not found' } });
    expect(await downloadChatMedia(PATH)).toBeNull();
  });

  it('falls back to octet-stream when the blob has no type', async () => {
    download.mockResolvedValue({ data: new Blob([new Uint8Array([1])]), error: null });
    expect((await downloadChatMedia(PATH))?.contentType).toBe('application/octet-stream');
  });
});

describe('signChatMediaUrl', () => {
  it('signs a chat-media URL for the requested lifetime', async () => {
    createSignedUrl.mockResolvedValue({
      data: { signedUrl: 'https://abc.supabase.co/storage/v1/object/sign/chat-media/x?token=t' },
      error: null,
    });
    const out = await signChatMediaUrl(PUBLIC, 3600);
    expect(createSignedUrl).toHaveBeenCalledWith(PATH, 3600);
    expect(out).toBe('https://abc.supabase.co/storage/v1/object/sign/chat-media/x?token=t');
  });

  it('returns other URLs and nullish values unchanged without touching storage', async () => {
    expect(await signChatMediaUrl('https://example.com/a.png', 60)).toBe('https://example.com/a.png');
    expect(await signChatMediaUrl(null, 60)).toBeNull();
    expect(createSignedUrl).not.toHaveBeenCalled();
  });

  it('falls back to the original URL when signing fails', async () => {
    createSignedUrl.mockResolvedValue({ data: null, error: { message: 'boom' } });
    expect(await signChatMediaUrl(PUBLIC, 60)).toBe(PUBLIC);
  });
});
