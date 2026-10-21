import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// Stub the Meta resumable upload so the helper is tested in isolation.
vi.mock('./meta-api', () => ({
  uploadResumableMedia: vi.fn(async () => ({ handle: 'HANDLE123' })),
}));

const { downloadChatMedia } = vi.hoisted(() => ({ downloadChatMedia: vi.fn() }));
vi.mock('@/lib/storage/chat-media-server', () => ({ downloadChatMedia }));

import { ensureImageHeaderHandle } from './template-header-handle';
import { uploadResumableMedia } from './meta-api';
import type { TemplatePayload } from './template-validators';

function payload(over: Partial<TemplatePayload> = {}): TemplatePayload {
  return {
    name: 't',
    category: 'Utility',
    language: 'en_US',
    body_text: 'hi',
    header_type: 'image',
    header_media_url: 'https://x.test/img.jpg',
    ...over,
  };
}

function imgResponse(type = 'image/jpeg', size = 1024, ok = true, status = 200): Response {
  return {
    ok,
    status,
    headers: { get: (h: string) => (h.toLowerCase() === 'content-type' ? type : null) },
    arrayBuffer: async () => new ArrayBuffer(size),
  } as unknown as Response;
}

describe('ensureImageHeaderHandle', () => {
  beforeEach(() => {
    vi.mocked(uploadResumableMedia).mockClear();
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it('is a no-op for non-image headers', async () => {
    const p = payload({ header_type: 'text', header_content: 'Hi' });
    await ensureImageHeaderHandle(p, 'tok');
    expect(uploadResumableMedia).not.toHaveBeenCalled();
    expect(p.header_handle).toBeUndefined();
  });

  it('is a no-op when a handle already exists', async () => {
    const p = payload({ header_handle: 'existing' });
    await ensureImageHeaderHandle(p, 'tok');
    expect(uploadResumableMedia).not.toHaveBeenCalled();
    expect(p.header_handle).toBe('existing');
  });

  it('throws an actionable error when META_APP_ID is unset', async () => {
    const p = payload();
    await expect(ensureImageHeaderHandle(p, 'tok')).rejects.toThrow(/META_APP_ID/);
  });

  it('derives + sets header_handle from a valid image URL', async () => {
    vi.stubEnv('META_APP_ID', 'app-1');
    vi.stubGlobal('fetch', vi.fn(async () => imgResponse('image/jpeg', 2048)));
    const p = payload();
    await ensureImageHeaderHandle(p, 'tok');
    expect(uploadResumableMedia).toHaveBeenCalledOnce();
    expect(p.header_handle).toBe('HANDLE123');
  });

  it('rejects a non-image content type', async () => {
    vi.stubEnv('META_APP_ID', 'app-1');
    vi.stubGlobal('fetch', vi.fn(async () => imgResponse('text/html')));
    await expect(ensureImageHeaderHandle(payload(), 'tok')).rejects.toThrow(/JPEG or PNG/);
  });

  it('rejects an image over 5 MB', async () => {
    vi.stubEnv('META_APP_ID', 'app-1');
    vi.stubGlobal('fetch', vi.fn(async () => imgResponse('image/png', 6 * 1024 * 1024)));
    await expect(ensureImageHeaderHandle(payload(), 'tok')).rejects.toThrow(/5 MB/);
  });
});

describe('ensureImageHeaderHandle — chat-media header URLs', () => {
  const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
  const URL_ = `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${ACCT}/1-header.png`;

  beforeEach(() => {
    vi.mocked(uploadResumableMedia).mockClear();
    downloadChatMedia.mockReset();
    vi.stubEnv('META_APP_ID', 'app-1');
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it('reads the object with the service role, not an anonymous fetch', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    downloadChatMedia.mockResolvedValue({ bytes: new ArrayBuffer(1024), contentType: 'image/png' });

    const p = payload({ header_media_url: URL_ });
    await ensureImageHeaderHandle(p, 'tok');

    expect(fetchMock).not.toHaveBeenCalled();
    expect(downloadChatMedia).toHaveBeenCalledWith(`account-${ACCT}/1-header.png`);
    expect(p.header_handle).toBe('HANDLE123');
    expect(vi.mocked(uploadResumableMedia).mock.calls[0][0]).toMatchObject({
      mimeType: 'image/png',
      fileName: 'header.png',
    });
  });

  it('keeps the type and size validation', async () => {
    downloadChatMedia.mockResolvedValueOnce({ bytes: new ArrayBuffer(8), contentType: 'image/gif' });
    await expect(
      ensureImageHeaderHandle(payload({ header_media_url: URL_ }), 'tok'),
    ).rejects.toThrow(/JPEG or PNG/);

    downloadChatMedia.mockResolvedValueOnce({
      bytes: new ArrayBuffer(6 * 1024 * 1024),
      contentType: 'image/png',
    });
    await expect(
      ensureImageHeaderHandle(payload({ header_media_url: URL_ }), 'tok'),
    ).rejects.toThrow(/5 MB/);
  });

  it('throws a clear error when the object cannot be read', async () => {
    downloadChatMedia.mockResolvedValue(null);
    await expect(
      ensureImageHeaderHandle(payload({ header_media_url: URL_ }), 'tok'),
    ).rejects.toThrow(/Could not read the header image/);
  });
});
