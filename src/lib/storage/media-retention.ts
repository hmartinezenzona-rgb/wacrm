// ============================================================
// 90-day retention for chat media.
//
// The bucket is the only thing in this system that grows without bound,
// and the Free plan allows 1 GB. The panel keeps every message forever;
// what expires is the FILE, by object age — never by conversation, so an
// old thread does not lose its recent photos.
//
// Deleting is irreversible, so:
//   * a dry run reports exactly what the real run would delete, and
//   * every run has a cap, which is what makes it safe to call from a cron
//     tick and safe to re-run (already-deleted objects are simply gone).
//
// Message rows and `media_url` are never touched: the panel renders the
// media as unavailable instead of losing the message.
// ============================================================

export interface RetentionEntry {
  /** Object name inside the prefix, e.g. `1700-wa-1.jpg`. */
  name: string;
  /** ISO timestamp of the object; null when Storage did not report one. */
  createdAt: string | null;
}

export interface RetentionStorage {
  list(
    prefix: string,
    options: { limit: number; offset: number },
  ): Promise<{ entries: RetentionEntry[]; hasMore: boolean; error?: string }>;
  remove(paths: string[]): Promise<{ error?: string }>;
}

export interface RetentionDb {
  /** Account prefixes to walk, e.g. `account-<uuid>`. */
  listAccountPrefixes(): Promise<string[]>;
}

export interface RetentionOptions {
  olderThanDays?: number;
  /** Objects deleted per run; also the guard against a surprise. */
  cap?: number;
  batchSize?: number;
  dryRun?: boolean;
  now?: () => number;
}

export interface RetentionResult {
  accounts: number;
  /** Objects inspected (originals only). */
  scanned: number;
  /** Originals to delete (or deleted, on a real run). */
  wouldDelete: number;
  /** Thumbnail siblings found for them. */
  wouldDeleteThumbs: number;
  /** True when the run stopped because the cap was reached. */
  capped: boolean;
  dryRun: boolean;
}

const DAY_MS = 24 * 60 * 60 * 1000;

/** `1700-wa-1.jpg` → `thumbs/1700-wa-1.webp`. */
export function thumbNameFor(name: string): string {
  return `thumbs/${name.replace(/\.[^.]*$/, '')}.webp`;
}

/**
 * Delete objects older than the window, in batches, up to `cap`.
 *
 * Only top-level objects are considered: a `thumbs/` entry is deleted
 * together with its original and never counted as an original itself.
 */
export async function runRetention(
  storage: RetentionStorage,
  db: RetentionDb,
  options: RetentionOptions = {},
): Promise<RetentionResult> {
  const olderThanDays = options.olderThanDays ?? 90;
  const cap = options.cap ?? 500;
  const batchSize = options.batchSize ?? 200;
  const dryRun = options.dryRun ?? false;
  const now = options.now ?? Date.now;
  const cutoff = now() - olderThanDays * DAY_MS;

  const result: RetentionResult = {
    accounts: 0,
    scanned: 0,
    wouldDelete: 0,
    wouldDeleteThumbs: 0,
    capped: false,
    dryRun,
  };

  const prefixes = await db.listAccountPrefixes();
  result.accounts = prefixes.length;

  for (const prefix of prefixes) {
    if (result.wouldDelete >= cap) {
      result.capped = true;
      break;
    }

    let offset = 0;
    for (;;) {
      const page = await storage.list(prefix, { limit: batchSize, offset });
      if (page.error) {
        console.error(`[media-retention] could not list ${prefix}: ${page.error}`);
        break;
      }

      const names = new Set(page.entries.map((e) => e.name));
      const doomed: string[] = [];
      const doomedThumbs: string[] = [];

      for (const entry of page.entries) {
        if (entry.name.startsWith('thumbs/')) continue; // handled with its original
        result.scanned++;
        if (!entry.createdAt) continue;
        const created = Date.parse(entry.createdAt);
        if (!Number.isFinite(created) || created >= cutoff) continue;

        // Check the cap BEFORE taking the object, so a run never overshoots.
        if (result.wouldDelete + doomed.length >= cap) break;
        doomed.push(`${prefix}/${entry.name}`);
        const thumb = thumbNameFor(entry.name);
        if (names.has(thumb)) {
          doomedThumbs.push(`${prefix}/${thumb}`);
        }
      }

      if (doomed.length > 0) {
        if (!dryRun) {
          const removed = await storage.remove([...doomed, ...doomedThumbs]);
          if (removed.error) {
            console.error(`[media-retention] remove failed: ${removed.error}`);
            break;
          }
        }
        result.wouldDelete += doomed.length;
        result.wouldDeleteThumbs += doomedThumbs.length;
      }

      if (!page.hasMore) break;
      if (result.wouldDelete >= cap) {
        result.capped = true;
        break;
      }
      offset += batchSize;
    }
  }

  return result;
}
