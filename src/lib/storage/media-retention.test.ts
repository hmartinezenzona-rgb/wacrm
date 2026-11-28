import { describe, expect, it, vi } from 'vitest';

import {
  runRetention,
  thumbNameFor,
  type RetentionDb,
  type RetentionEntry,
  type RetentionStorage,
} from './media-retention';

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse('2026-11-28T12:00:00Z');

function isoDaysAgo(days: number): string {
  return new Date(NOW - days * DAY).toISOString();
}

function makeStorage(objects: Array<{ prefix: string } & RetentionEntry>) {
  const removed: string[][] = [];
  const storage: RetentionStorage = {
    list: async (prefix, { limit, offset }) => {
      const mine = objects.filter((o) => o.prefix === prefix);
      return {
        entries: mine.slice(offset, offset + limit).map(({ name, createdAt }) => ({ name, createdAt })),
        hasMore: offset + limit < mine.length,
      };
    },
    remove: async (paths) => {
      removed.push(paths);
      return {};
    },
  };
  return { storage, removed };
}

const db: RetentionDb = {
  listAccountPrefixes: async () => ['account-a', 'account-b'],
};

describe('thumbNameFor', () => {
  it('maps an original to its sibling', () => {
    expect(thumbNameFor('1700-wa-1.jpg')).toBe('thumbs/1700-wa-1.webp');
    expect(thumbNameFor('no-extension')).toBe('thumbs/no-extension.webp');
  });
});

describe('runRetention', () => {
  it('deletes the original and its thumbnail when older than the window', async () => {
    const { storage, removed } = makeStorage([
      { prefix: 'account-a', name: 'old.jpg', createdAt: isoDaysAgo(120) },
      { prefix: 'account-a', name: 'thumbs/old.webp', createdAt: isoDaysAgo(120) },
      { prefix: 'account-a', name: 'new.jpg', createdAt: isoDaysAgo(10) },
    ]);

    const result = await runRetention(storage, db, { now: () => NOW });

    expect(result).toMatchObject({ wouldDelete: 1, wouldDeleteThumbs: 1, capped: false });
    expect(removed).toEqual([['account-a/old.jpg', 'account-a/thumbs/old.webp']]);
  });

  it('a thumbnail without its original is not counted as an original', async () => {
    const { storage } = makeStorage([
      { prefix: 'account-a', name: 'thumbs/orphan.webp', createdAt: isoDaysAgo(200) },
    ]);

    const result = await runRetention(storage, db, { now: () => NOW });

    expect(result.scanned).toBe(0);
    expect(result.wouldDelete).toBe(0);
  });

  it('keeps the boundary: exactly 90 days is not deleted', async () => {
    const { storage } = makeStorage([
      { prefix: 'account-a', name: 'edge.jpg', createdAt: isoDaysAgo(90) },
      { prefix: 'account-a', name: 'just-over.jpg', createdAt: new Date(NOW - 90 * DAY - 1000).toISOString() },
    ]);

    const result = await runRetention(storage, db, { now: () => NOW });

    expect(result.wouldDelete).toBe(1);
  });

  it('does not upload, list outside the accounts, or touch rows', async () => {
    // There is no row API here at all: retention can only remove objects.
    const { storage } = makeStorage([
      { prefix: 'account-a', name: 'old.jpg', createdAt: isoDaysAgo(200) },
    ]);
    const listSpy = vi.spyOn(storage, 'list');

    await runRetention(storage, db, { now: () => NOW });

    const prefixes = listSpy.mock.calls.map((c) => c[0]);
    expect(new Set(prefixes)).toEqual(new Set(['account-a', 'account-b']));
  });

  it('the dry run deletes nothing and counts the same as the real run', async () => {
    const objects = [
      { prefix: 'account-a', name: 'old1.jpg', createdAt: isoDaysAgo(120) },
      { prefix: 'account-a', name: 'thumbs/old1.webp', createdAt: isoDaysAgo(120) },
      { prefix: 'account-b', name: 'old2.jpg', createdAt: isoDaysAgo(300) },
    ];
    const dry = makeStorage(objects);
    const real = makeStorage(objects);

    const dryResult = await runRetention(dry.storage, db, { now: () => NOW, dryRun: true });
    const realResult = await runRetention(real.storage, db, { now: () => NOW });

    expect(dry.removed).toHaveLength(0);
    expect(dryResult).toMatchObject({
      wouldDelete: realResult.wouldDelete,
      wouldDeleteThumbs: realResult.wouldDeleteThumbs,
      dryRun: true,
    });
    expect(real.removed.length).toBeGreaterThan(0);
  });

  it('stops at the cap and says so', async () => {
    const objects = Array.from({ length: 10 }, (_, i) => ({
      prefix: 'account-a',
      name: `old-${i}.jpg`,
      createdAt: isoDaysAgo(120),
    }));
    const { storage } = makeStorage(objects);

    const result = await runRetention(storage, db, { now: () => NOW, cap: 4 });

    expect(result.wouldDelete).toBe(4);
    expect(result.capped).toBe(true);
  });

  it('pages through a large prefix', async () => {
    const objects = Array.from({ length: 7 }, (_, i) => ({
      prefix: 'account-a',
      name: `old-${i}.jpg`,
      createdAt: isoDaysAgo(120),
    }));
    const { storage } = makeStorage(objects);

    const result = await runRetention(storage, db, { now: () => NOW, batchSize: 2 });

    expect(result.wouldDelete).toBe(7);
  });

  it('an object with no timestamp is left alone', async () => {
    const { storage } = makeStorage([
      { prefix: 'account-a', name: 'unknown.jpg', createdAt: null },
    ]);

    const result = await runRetention(storage, db, { now: () => NOW });

    expect(result.wouldDelete).toBe(0);
  });

  it('reports a removal error without throwing', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const storage: RetentionStorage = {
      list: async () => ({
        entries: [{ name: 'old.jpg', createdAt: isoDaysAgo(120) }],
        hasMore: false,
      }),
      remove: async () => ({ error: 'bucket refused' }),
    };

    const result = await runRetention(storage, db, { now: () => NOW });
    errorSpy.mockRestore();

    expect(result.wouldDelete).toBe(0);
  });
});
