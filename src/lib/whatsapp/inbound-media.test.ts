import { beforeEach, describe, expect, it, vi } from 'vitest';

// Settlement of an inbound media message (slice 6a). The Meta calls, the
// bucket and the message update are all faked; what the tests pin is the
// contract: bounded calls, one retry, the size cap, the guarded writes, and
// the fact that a failure never throws.

const getMediaUrl = vi.fn();
const downloadMedia = vi.fn();
vi.mock('@/lib/whatsapp/meta-api', () => ({
  getMediaUrl: (...a: unknown[]) => getMediaUrl(...a),
  downloadMedia: (...a: unknown[]) => downloadMedia(...a),
}));

const makeThumbnail = vi.fn();
vi.mock('@/lib/storage/media-thumbnail', () => ({
  makeThumbnail: (...a: unknown[]) => makeThumbnail(...a),
}));

interface UpdateRecord {
  payload: Record<string, unknown>;
  eqs: Array<[string, unknown]>;
}

const updates: UpdateRecord[] = [];
const uploads: Array<{ path: string; contentType: string; upsert: boolean }> = [];
let failUploadFor: ((path: string) => boolean) | null = null;

vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({
    storage: {
      from: () => ({
        upload: async (
          path: string,
          _data: unknown,
          opts: { contentType: string; upsert?: boolean },
        ) => {
          if (failUploadFor && failUploadFor(path)) {
            return { error: { message: 'bucket refused' } };
          }
          uploads.push({ path, contentType: opts.contentType, upsert: !!opts.upsert });
          return { error: null };
        },
      }),
    },
    from: () => {
      const record: UpdateRecord = { payload: {}, eqs: [] };
      const builder: Record<string, unknown> = {};
      builder.update = (payload: Record<string, unknown>) => {
        record.payload = payload;
        return builder;
      };
      builder.eq = (col: string, val: unknown) => {
        record.eqs.push([col, val]);
        return builder;
      };
      builder.then = (resolve: (v: unknown) => unknown) => {
        updates.push(record);
        return Promise.resolve({ error: null }).then(resolve);
      };
      return builder;
    },
  }),
}));

import {
  MEDIA_MAX_BYTES,
  settleInboundMedia,
  type SettleInboundMediaArgs,
} from './inbound-media';

const ARGS: SettleInboundMediaArgs = {
  messageId: 'msg-1',
  mediaId: 'meta-1',
  accessToken: 'token',
  accountId: 'acct-1',
  contentType: 'image',
  sleep: async () => {},
};

beforeEach(() => {
  vi.clearAllMocks();
  updates.length = 0;
  uploads.length = 0;
  failUploadFor = null;
  getMediaUrl.mockResolvedValue({ url: 'https://meta.test/media', mimeType: 'image/jpeg' });
  downloadMedia.mockResolvedValue({ buffer: Buffer.alloc(1024), contentType: 'image/jpeg' });
  makeThumbnail.mockResolvedValue({
    path: 'account-acct-1/thumbs/1-wa-meta-1.webp',
    data: Buffer.alloc(64),
    mime: 'image/webp',
    width: 360,
    height: 270,
    sourceWidth: 800,
    sourceHeight: 600,
  });
});

describe('settleInboundMedia', () => {
  it('stores the original and the thumbnail and settles ready', async () => {
    const out = await settleInboundMedia(ARGS);

    expect(out).toBe('ready');
    expect(uploads.map((u) => u.contentType)).toEqual(['image/jpeg', 'image/webp']);
    const last = updates.at(-1)!;
    expect(last.payload).toMatchObject({
      media_status: 'ready',
      media_mime: 'image/jpeg',
      media_bytes: 1024,
      media_width: 800,
      media_height: 600,
      media_thumb_path: 'account-acct-1/thumbs/1-wa-meta-1.webp',
      media_error: null,
    });
    expect(String(last.payload.media_path)).toMatch(/^account-acct-1\/\d+-wa-meta-1\.jpg$/);
  });

  it('every write is guarded by media_status = pending', async () => {
    await settleInboundMedia(ARGS);
    for (const record of updates) {
      expect(record.eqs).toContainEqual(['media_status', 'pending']);
      expect(record.eqs).toContainEqual(['id', 'msg-1']);
    }
  });

  it('bounds both Meta calls with an abort signal', async () => {
    await settleInboundMedia(ARGS);
    expect(getMediaUrl.mock.calls[0]![0]).toMatchObject({ mediaId: 'meta-1' });
    expect(getMediaUrl.mock.calls[0]![0].signal).toBeInstanceOf(AbortSignal);
    expect(downloadMedia.mock.calls[0]![0].signal).toBeInstanceOf(AbortSignal);
  });

  it('retries once and settles ready when the second attempt works', async () => {
    downloadMedia
      .mockRejectedValueOnce(new Error('network down'))
      .mockResolvedValueOnce({ buffer: Buffer.alloc(2048), contentType: 'image/jpeg' });

    const out = await settleInboundMedia(ARGS);

    expect(out).toBe('ready');
    expect(downloadMedia).toHaveBeenCalledTimes(2);
    expect(uploads).toHaveLength(2);
  });

  it('settles failed after two failed attempts, keeping media_url untouched', async () => {
    downloadMedia.mockRejectedValue(new Error('meta 500'));

    const out = await settleInboundMedia(ARGS);

    expect(out).toBe('failed');
    expect(downloadMedia).toHaveBeenCalledTimes(2);
    const last = updates.at(-1)!;
    expect(last.payload).toEqual({ media_status: 'failed', media_error: 'meta 500' });
    expect('media_url' in last.payload).toBe(false);
  });

  it('rejects an object over the bucket cap without uploading', async () => {
    downloadMedia.mockResolvedValue({
      buffer: Buffer.alloc(MEDIA_MAX_BYTES + 1),
      contentType: 'image/jpeg',
    });

    const out = await settleInboundMedia(ARGS);

    expect(out).toBe('failed');
    expect(uploads).toHaveLength(0);
  });

  it('keeps the message ready when only the thumbnail fails', async () => {
    makeThumbnail.mockResolvedValue({ error: 'corrupt image' });

    const out = await settleInboundMedia(ARGS);

    expect(out).toBe('ready');
    const last = updates.at(-1)!;
    expect(last.payload.media_thumb_path).toBeNull();
    expect(String(last.payload.media_error)).toContain('thumbnail: corrupt image');
  });

  it('keeps the message ready when only the thumbnail upload fails', async () => {
    failUploadFor = (path) => path.includes('/thumbs/');

    const out = await settleInboundMedia(ARGS);

    expect(out).toBe('ready');
    expect(uploads).toHaveLength(1); // the original
    const last = updates.at(-1)!;
    expect(last.payload.media_thumb_path).toBeNull();
    expect(String(last.payload.media_error)).toContain('thumbnail: bucket refused');
  });

  it('does not try a thumbnail for audio or documents', async () => {
    makeThumbnail.mockClear();
    const out = await settleInboundMedia({ ...ARGS, contentType: 'audio' });

    expect(out).toBe('ready');
    expect(makeThumbnail).not.toHaveBeenCalled();
    const last = updates.at(-1)!;
    expect(last.payload.media_thumb_path).toBeNull();
    expect(last.payload.media_width).toBeNull();
  });
});
