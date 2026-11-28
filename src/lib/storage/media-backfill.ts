// ============================================================
// Backfill of migration 400's metadata for images stored before it.
//
// Inbound media has been landing in the chat-media bucket since long
// before `media_status` existed, so every one of those rows is NULL and
// the panel still downloads the full original to paint a bubble. This
// walks the history (retained 90 days only), records what it finds, and
// produces the same small WebP sibling that ingest now writes.
//
// Rules:
//   * Originals are never re-encoded or replaced; the thumbnail is a new
//     object under `thumbs/` with `upsert: true`.
//   * Only images and stickers are downloaded. Everything else gets its
//     metadata recorded from the stored URL without touching the bytes.
//   * `< 24 h`-old Meta proxy URLs (`/api/whatsapp/media/...`) are counted
//     and left alone: that object is not ours to keep.
//   * A dry run writes nothing and reports exactly the counters the real
//     run would produce on the same data.
//
// The module takes `db` and `storage` as arguments so the CLI and the
// tests drive the same code without importing a Supabase client.
// ============================================================

// Relative on purpose: the CLI runner executes this file through
// `node --experimental-strip-types`, which does not resolve the `@/` alias.
import { makeThumbnail, thumbnailPathFor } from './media-thumbnail.ts';

export interface BackfillRow {
  id: string;
  media_url: string | null;
  content_type: string | null;
  created_at: string;
}

export interface BackfillStorage {
  /** Object names directly under `prefix` (a directory), paged. */
  list(
    prefix: string,
    options: { limit: number; offset: number },
  ): Promise<{ names: string[]; hasMore: boolean; error?: string }>;
  download(path: string): Promise<Buffer | null>;
  upload(
    path: string,
    data: Buffer,
    options: { contentType: string; upsert: boolean },
  ): Promise<{ error?: string }>;
}

export interface BackfillDb {
  selectBatch(after: Cursor | null, limit: number): Promise<BackfillRow[]>;
  markReady(id: string, values: BackfillReadyValues): Promise<void>;
  markFailed(id: string, error: string): Promise<void>;
}

export interface BackfillReadyValues {
  media_status: 'ready';
  media_path: string;
  media_thumb_path: string | null;
  media_mime: string | null;
  media_bytes: number | null;
  media_width: number | null;
  media_height: number | null;
  media_error: string | null;
}

export interface Cursor {
  createdAt: string;
  id: string;
}

export interface BackfillCounters {
  /** An image got a thumbnail. */
  would_ready_with_thumb: number;
  /** A non-image (or an image with no readable pixels) recorded without one. */
  would_ready_no_thumb: number;
  /** The object is gone from the bucket. */
  would_fail_missing: number;
  /** `< 24 h`-old Meta proxy URL: not ours, left untouched. */
  legacy_meta: number;
}

/** Run `fn` over `items` with at most `limit` in flight. */
async function mapWithConcurrency<T>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<void>,
): Promise<void> {
  if (limit <= 1) {
    for (const item of items) await fn(item);
    return;
  }
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    for (;;) {
      const index = next++;
      if (index >= items.length) return;
      await fn(items[index]!);
    }
  });
  await Promise.all(workers);
}

export interface BackfillRunResult {
  counters: BackfillCounters;
  /** Cursor to resume from, or null when the selection is exhausted. */
  nextCursor: Cursor | null;
  /** Rows looked at, matching or not. */
  scanned: number;
}

export function emptyCounters(): BackfillCounters {
  return {
    would_ready_with_thumb: 0,
    would_ready_no_thumb: 0,
    would_fail_missing: 0,
    legacy_meta: 0,
  };
}

/** `.../object/public/chat-media/account-x/1.jpg` → `account-x/1.jpg`. */
export function pathFromMediaUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  const marker = '/chat-media/';
  const at = url.indexOf(marker);
  if (at < 0) return null;
  const path = url.slice(at + marker.length).split(/[?#]/)[0];
  return path.startsWith('account-') && path.includes('/') ? path : null;
}

/** The account prefix an object lives under. */
export function accountOfPath(path: string): string | null {
  const match = /^(account-[A-Za-z0-9_-]+)\//.exec(path);
  return match ? match[1] : null;
}

/** Object names under one account prefix, following `list` pagination. */
async function listAccountObjects(
  storage: BackfillStorage,
  account: string,
  pageSize = 1000,
): Promise<Set<string> | null> {
  const names = new Set<string>();
  let offset = 0;
  for (;;) {
    const page = await storage.list(account, { limit: pageSize, offset });
    if (page.error) return null;
    for (const name of page.names) names.add(name);
    if (!page.hasMore) break;
    offset += pageSize;
  }
  return names;
}

/**
 * Process one row. Returns the counter it fed, or null when the row is not
 * this backfill's business (no chat-media path).
 */
async function processRow(
  row: BackfillRow,
  objects: Set<string>,
  deps: { db: BackfillDb; storage: BackfillStorage; dryRun: boolean },
  counters: BackfillCounters,
): Promise<void> {
  const { db, storage, dryRun } = deps;

  // Meta's own proxy URL: the object is not in our bucket.
  if (row.media_url && row.media_url.includes('/api/whatsapp/media/')) {
    counters.legacy_meta++;
    return;
  }

  const path = pathFromMediaUrl(row.media_url);
  if (!path) return;

  const account = accountOfPath(path);
  const name = path.slice((account ?? '').length + 1);
  if (!account || !objects.has(name)) {
    counters.would_fail_missing++;
    if (!dryRun) await db.markFailed(row.id, 'object missing');
    return;
  }

  const isImage = row.content_type === 'image' || row.content_type === 'sticker';

  if (!isImage) {
    // No download, no thumbnail: record where the object is and move on.
    counters.would_ready_no_thumb++;
    if (!dryRun) {
      await db.markReady(row.id, {
        media_status: 'ready',
        media_path: path,
        media_thumb_path: null,
        media_mime: null,
        media_bytes: null,
        media_width: null,
        media_height: null,
        media_error: null,
      });
    }
    return;
  }

  const bytes = await storage.download(path);
  if (!bytes) {
    counters.would_fail_missing++;
    if (!dryRun) await db.markFailed(row.id, 'object missing');
    return;
  }

  const thumb = await makeThumbnail(path, bytes);
  if (thumb && 'error' in thumb) {
    counters.would_ready_no_thumb++;
    if (!dryRun) {
      await db.markReady(row.id, {
        media_status: 'ready',
        media_path: path,
        media_thumb_path: null,
        media_mime: null,
        media_bytes: bytes.byteLength,
        media_width: null,
        media_height: null,
        media_error: `thumbnail: ${thumb.error}`,
      });
    }
    return;
  }
  if (!thumb) {
    counters.would_ready_no_thumb++;
    if (!dryRun) await db.markReady(row.id, {
      media_status: 'ready',
      media_path: path,
      media_thumb_path: null,
      media_mime: null,
      media_bytes: bytes.byteLength,
      media_width: null,
      media_height: null,
      media_error: null,
    });
    return;
  }

  counters.would_ready_with_thumb++;
  if (!dryRun) {
    const thumbPath = thumbnailPathFor(path) ?? thumb.path;
    const uploaded = await storage.upload(thumbPath, thumb.data, {
      contentType: 'image/webp',
      upsert: true,
    });
    await db.markReady(row.id, {
      media_status: 'ready',
      media_path: path,
      media_thumb_path: uploaded.error ? null : thumbPath,
      media_mime: null,
      media_bytes: bytes.byteLength,
      media_width: thumb.sourceWidth,
      media_height: thumb.sourceHeight,
      media_error: uploaded.error ? `thumbnail: ${uploaded.error}` : null,
    });
  }
}

/**
 * One batch: page the selection, group by account so the bucket is listed
 * once per account, and process each row.
 */
export async function runBackfillBatch(
  deps: { db: BackfillDb; storage: BackfillStorage; dryRun: boolean },
  options: { after: Cursor | null; limit: number; concurrency?: number },
): Promise<BackfillRunResult> {
  const counters = emptyCounters();
  const rows = await deps.db.selectBatch(options.after, options.limit);
  if (rows.length === 0) {
    return { counters, nextCursor: null, scanned: 0 };
  }

  const byAccount = new Map<string, BackfillRow[]>();
  for (const row of rows) {
    if (row.media_url && row.media_url.includes('/api/whatsapp/media/')) {
      counters.legacy_meta++;
      continue;
    }
    const path = pathFromMediaUrl(row.media_url);
    const account = path ? accountOfPath(path) : null;
    if (!path || !account) continue;
    const list = byAccount.get(account) ?? [];
    list.push(row);
    byAccount.set(account, list);
  }

  for (const [account, accountRows] of byAccount) {
    const objects = await listAccountObjects(deps.storage, account);
    if (!objects) {
      console.error(`[media-backfill] could not list ${account}`);
      continue;
    }
    // Serial by default; the CLI raises this to trade politeness for time.
    await mapWithConcurrency(accountRows, options.concurrency ?? 1, (row) =>
      processRow(row, objects, deps, counters),
    );
  }

  const last = rows[rows.length - 1];
  return {
    counters,
    scanned: rows.length,
    nextCursor: last ? { createdAt: last.created_at, id: last.id } : null,
  };
}

export interface BackfillRunOptions {
  batchSize?: number;
  /** Rows processed in parallel inside a batch (default 1). */
  concurrency?: number;
  limit?: number;
  sleepMs?: number;
  after?: Cursor | null;
  onBatch?: (result: BackfillRunResult, total: BackfillCounters) => void;
  sleep?: (ms: number) => Promise<void>;
}

/** Run batch after batch until the selection is exhausted or `limit` is hit. */
export async function runBackfill(
  deps: { db: BackfillDb; storage: BackfillStorage; dryRun: boolean },
  options: BackfillRunOptions = {},
): Promise<{ total: BackfillCounters; batches: number; nextCursor: Cursor | null }> {
  const batchSize = options.batchSize ?? 200;
  const total = emptyCounters();
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  let cursor = options.after ?? null;
  let batches = 0;
  let processed = 0;

  for (;;) {
    if (options.limit !== undefined && processed >= options.limit) break;
    const remaining =
      options.limit === undefined ? batchSize : Math.min(batchSize, options.limit - processed);

    const result = await runBackfillBatch(deps, {
      after: cursor,
      limit: remaining,
      concurrency: options.concurrency,
    });
    batches++;
    for (const key of Object.keys(total) as (keyof BackfillCounters)[]) {
      total[key] += result.counters[key];
    }
    processed += result.scanned;
    options.onBatch?.(result, total);

    // A short batch means the selection is exhausted: the next call would
    // come back empty, so stop here instead of paying for it.
    if (!result.nextCursor || result.scanned < remaining) {
      cursor = null;
      break;
    }
    cursor = result.nextCursor;
    if (options.sleepMs) await sleep(options.sleepMs);
  }

  return { total, batches, nextCursor: cursor };
}
