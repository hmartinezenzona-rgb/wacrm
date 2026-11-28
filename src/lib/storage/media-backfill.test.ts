import { describe, expect, it, vi } from 'vitest';
import sharp from 'sharp';

import {
  accountOfPath,
  emptyCounters,
  pathFromMediaUrl,
  runBackfill,
  runBackfillBatch,
  type BackfillDb,
  type BackfillRow,
  type BackfillStorage,
} from './media-backfill';

const PUB = 'https://proj.supabase.co/storage/v1/object/public/chat-media';

function makeDb(rows: BackfillRow[]) {
  const ready: Array<{ id: string; values: Record<string, unknown> }> = [];
  const failed: Array<{ id: string; error: string }> = [];
  const cursors: Array<unknown> = [];
  const db: BackfillDb = {
    selectBatch: async (after, limit) => {
      cursors.push(after);
      const start = after
        ? rows.findIndex(
            (r) => r.created_at === after.createdAt && r.id === after.id,
          ) + 1
        : 0;
      return rows.slice(start, start + limit);
    },
    markReady: async (id, values) => {
      ready.push({ id, values: values as unknown as Record<string, unknown> });
    },
    markFailed: async (id, error) => {
      failed.push({ id, error });
    },
  };
  return { db, ready, failed, cursors };
}

function makeStorage(objects: Record<string, Buffer | null>) {
  const uploads: Array<{ path: string; upsert: boolean; type: string }> = [];
  const downloads: string[] = [];
  const storage: BackfillStorage = {
    list: async (prefix) => ({
      names: Object.keys(objects)
        .filter((p) => p.startsWith(`${prefix}/`) && !p.slice(prefix.length + 1).includes('/'))
        .map((p) => p.slice(prefix.length + 1)),
      hasMore: false,
    }),
    download: async (path) => {
      downloads.push(path);
      return objects[path] ?? null;
    },
    upload: async (path, _data, options) => {
      uploads.push({ path, upsert: options.upsert, type: options.contentType });
      return {};
    },
  };
  return { storage, uploads, downloads };
}

async function jpeg(width = 400, height = 300): Promise<Buffer> {
  const raw = Buffer.alloc(width * height * 3, 90);
  return sharp(raw, { raw: { width, height, channels: 3 } }).jpeg().toBuffer();
}

function row(over: Partial<BackfillRow> & { id: string }): BackfillRow {
  return {
    media_url: `${PUB}/account-acct1/${over.id}.jpg`,
    content_type: 'image',
    created_at: '2026-11-01T00:00:00Z',
    ...over,
  };
}

describe('path helpers', () => {
  it('reads the object path out of a stored URL', () => {
    expect(pathFromMediaUrl(`${PUB}/account-a/x.jpg`)).toBe('account-a/x.jpg');
    expect(pathFromMediaUrl(`${PUB}/account-a/x.jpg?t=1`)).toBe('account-a/x.jpg');
  });

  it('refuses anything that is not one of our objects', () => {
    expect(pathFromMediaUrl('https://cdn.example.com/a.jpg')).toBeNull();
    expect(pathFromMediaUrl('/api/whatsapp/media/123')).toBeNull();
    expect(pathFromMediaUrl(null)).toBeNull();
  });

  it('reads the account prefix', () => {
    expect(accountOfPath('account-a/x.jpg')).toBe('account-a');
    expect(accountOfPath('thumbs/x.jpg')).toBeNull();
  });
});

describe('runBackfillBatch', () => {
  it('creates the thumbnail sibling with upsert and records the dimensions', async () => {
    const bytes = await jpeg();
    const { db, ready } = makeDb([row({ id: 'm1' })]);
    const { storage, uploads } = makeStorage({ 'account-acct1/m1.jpg': bytes });

    const result = await runBackfillBatch({ db, storage, dryRun: false }, { after: null, limit: 10 });

    expect(result.counters).toEqual({ ...emptyCounters(), would_ready_with_thumb: 1 });
    expect(uploads).toEqual([
      { path: 'account-acct1/thumbs/m1.webp', upsert: true, type: 'image/webp' },
    ]);
    expect(ready[0]!.values).toMatchObject({
      media_status: 'ready',
      media_path: 'account-acct1/m1.jpg',
      media_thumb_path: 'account-acct1/thumbs/m1.webp',
      media_width: 400,
      media_height: 300,
    });
  });

  it('a missing object becomes failed and nothing is written as ready', async () => {
    const { db, ready, failed } = makeDb([row({ id: 'm2' })]);
    const { storage } = makeStorage({});

    const result = await runBackfillBatch({ db, storage, dryRun: false }, { after: null, limit: 10 });

    expect(result.counters).toEqual({ ...emptyCounters(), would_fail_missing: 1 });
    expect(failed).toEqual([{ id: 'm2', error: 'object missing' }]);
    expect(ready).toHaveLength(0);
  });

  it('legacy Meta URLs are counted and never touched', async () => {
    const { db, ready, failed } = makeDb([
      row({ id: 'm3', media_url: '/api/whatsapp/media/12345' }),
    ]);
    const { storage, downloads } = makeStorage({});

    const result = await runBackfillBatch({ db, storage, dryRun: false }, { after: null, limit: 10 });

    expect(result.counters).toEqual({ ...emptyCounters(), legacy_meta: 1 });
    expect(ready).toHaveLength(0);
    expect(failed).toHaveLength(0);
    expect(downloads).toHaveLength(0);
  });

  it('never downloads a video or a document', async () => {
    const { db, ready } = makeDb([
      row({ id: 'v1', content_type: 'video' }),
      row({ id: 'd1', content_type: 'document' }),
    ]);
    const { storage, downloads } = makeStorage({
      'account-acct1/v1.jpg': Buffer.from('x'),
      'account-acct1/d1.jpg': Buffer.from('x'),
    });

    const result = await runBackfillBatch({ db, storage, dryRun: false }, { after: null, limit: 10 });

    expect(downloads).toHaveLength(0);
    expect(result.counters).toEqual({ ...emptyCounters(), would_ready_no_thumb: 2 });
    expect(ready.map((r) => r.values.media_thumb_path)).toEqual([null, null]);
  });

  it('a corrupt image is recorded ready without a thumbnail', async () => {
    const { db, ready } = makeDb([row({ id: 'm4' })]);
    const { storage } = makeStorage({
      'account-acct1/m4.jpg': Buffer.from('definitely not an image'),
    });

    const result = await runBackfillBatch({ db, storage, dryRun: false }, { after: null, limit: 10 });

    expect(result.counters).toEqual({ ...emptyCounters(), would_ready_no_thumb: 1 });
    expect(ready[0]!.values.media_thumb_path).toBeNull();
  });
});

describe('dry run', () => {
  it('writes nothing and counts exactly what the real run would', async () => {
    const bytes = await jpeg();
    const rows = [
      row({ id: 'a1' }),
      row({ id: 'a2', content_type: 'audio' }),
      row({ id: 'a3' }),
      row({ id: 'a4', media_url: '/api/whatsapp/media/999' }),
    ];
    const objects = { 'account-acct1/a1.jpg': bytes, 'account-acct1/a2.jpg': bytes };

    const dry = makeDb(rows);
    const dryStorage = makeStorage(objects);
    const dryResult = await runBackfillBatch(
      { db: dry.db, storage: dryStorage.storage, dryRun: true },
      { after: null, limit: 10 },
    );

    expect(dry.ready).toHaveLength(0);
    expect(dry.failed).toHaveLength(0);
    expect(dryStorage.uploads).toHaveLength(0);

    const real = makeDb(rows);
    const realStorage = makeStorage(objects);
    const realResult = await runBackfillBatch(
      { db: real.db, storage: realStorage.storage, dryRun: false },
      { after: null, limit: 10 },
    );

    expect(dryResult.counters).toEqual(realResult.counters);
    expect(dryResult.counters).toMatchObject({
      would_ready_with_thumb: 1,
      would_ready_no_thumb: 1,
      would_fail_missing: 1,
      legacy_meta: 1,
    });
  });
});

describe('runBackfill', () => {
  it('resumes from the cursor batch after batch', async () => {
    const bytes = await jpeg(120, 90);
    const rows = Array.from({ length: 5 }, (_, i) =>
      row({ id: `m${i}`, created_at: `2026-11-0${i + 1}T00:00:00Z` }),
    );
    const objects: Record<string, Buffer> = {};
    for (const r of rows) objects[`account-acct1/${r.id}.jpg`] = bytes;

    const { db, cursors } = makeDb(rows);
    const { storage } = makeStorage(objects);

    const result = await runBackfill(
      { db, storage, dryRun: true },
      { batchSize: 2 },
    );

    expect(result.total.would_ready_with_thumb).toBe(5);
    expect(result.batches).toBe(3);
    // First batch has no cursor; the next two resume from the previous tail.
    expect(cursors[0]).toBeNull();
    expect(cursors[1]).toMatchObject({ id: 'm1' });
    expect(cursors[2]).toMatchObject({ id: 'm3' });
  });

  it('stops at the row limit', async () => {
    const bytes = await jpeg(80, 80);
    const rows = Array.from({ length: 6 }, (_, i) => row({ id: `r${i}` }));
    const objects: Record<string, Buffer> = {};
    for (const r of rows) objects[`account-acct1/${r.id}.jpg`] = bytes;

    const { db } = makeDb(rows);
    const { storage } = makeStorage(objects);

    const result = await runBackfill({ db, storage, dryRun: true }, { batchSize: 2, limit: 3 });

    expect(result.total.would_ready_with_thumb).toBe(3);
  });
});
