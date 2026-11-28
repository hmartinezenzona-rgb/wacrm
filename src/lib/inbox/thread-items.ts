// Prepend-safe item model for the virtualized thread.
//
// One item per message; day separators live BELOW the last message of a day.
// This is what makes prepending older pages exact: no separator ever moves
// between items, so every already-loaded item keeps its height and its
// identity, and the only anchor change is `firstItemIndex` dropping by the
// number of prepended messages.
//
// `firstItemIndex` shifts the anchor and the item keys; it does NOT change
// the index space of the public index props. Virtuoso clamps
// `scrollToIndex`/`initialTopMostItemIndex` to `totalCount - 1`, which in the
// data-driven list is `data.length - 1`, so those props take the array
// position. `indexOfMessage` returns that position.

import { format, isSameDay, subDays } from 'date-fns';
import type { Message } from '@/types';

export interface ThreadItem {
  /** Message id; also the stable virtual key. */
  id: string;
  message: Message;
  /**
   * Original instant of the NEXT message when it falls on another day; the
   * separator label source. Carried as the instant, never as a `yyyy-MM-dd`
   * key, so the label can never be re-parsed as UTC midnight and shifted a
   * day back in western zones.
   */
  separatorBelowAt: string | null;
}

export interface ThreadItems {
  items: ThreadItem[];
  /** Original instant of the oldest loaded message; the header label source. */
  headerDayAt: string | null;
}

/** Minimal translator surface for the day labels. */
export type DayLabelTranslator = (key: 'today' | 'yesterday') => string;

/**
 * Day label for a message instant, evaluated in the viewer's local calendar.
 *
 * Takes the ORIGINAL instant (ISO string or Date), never a `yyyy-MM-dd` key:
 * `new Date("2026-11-27")` is UTC midnight, which is the previous local day in
 * every UTC-negative zone, so re-parsing a key labelled every separator one
 * day early. `now` is explicit so the result is testable across time zones.
 */
export function formatThreadDayLabel(
  instant: string | Date,
  now: Date,
  t: DayLabelTranslator,
): string {
  const date = typeof instant === 'string' ? new Date(instant) : instant;
  if (isSameDay(date, now)) return t('today');
  if (isSameDay(date, subDays(now, 1))) return t('yesterday');
  return format(date, 'MMMM d, yyyy');
}

/**
 * Starting value for `firstItemIndex`. Any large positive number works; it
 * only has to leave room to count downwards as history is prepended.
 */
export const THREAD_FIRST_ITEM_INDEX_BASE = 1_000_000;

/** Local calendar day key, matching the grouping the thread used before. */
function dayKey(message: Message): string {
  return format(new Date(message.created_at), 'yyyy-MM-dd');
}

/** Build the thread item list and the oldest-day header source. */
export function buildThreadItems(messages: Message[]): ThreadItems {
  if (messages.length === 0) return { items: [], headerDayAt: null };

  const items: ThreadItem[] = messages.map((message, index) => {
    const day = dayKey(message);
    const next = messages[index + 1];
    // The next day key is only compared for the boundary; it is never stored,
    // so no caller can label a separator from a `yyyy-MM-dd` key.
    const boundary = !!(next && dayKey(next) !== day);
    return {
      id: message.id,
      message,
      separatorBelowAt: boundary ? next!.created_at : null,
    };
  });

  return {
    items,
    headerDayAt: messages[0].created_at,
  };
}

/**
 * Splits a server timestamp into the whole-second epoch and the exact
 * fractional digits. Postgres keeps microseconds, and the keyset contract
 * deliberately round-trips the raw string to preserve them; `new Date(...)`
 * would truncate to milliseconds and let the sub-millisecond order decide the
 * tie-break instead of the timestamp.
 */
const SERVER_TIMESTAMP =
  /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})$/;

function parseServerTimestamp(raw: string): { secondsMs: number; fraction: string } | null {
  const match = SERVER_TIMESTAMP.exec(raw);
  if (!match) return null;
  const secondsMs = Date.parse(`${match[1]}${match[3]}`);
  if (Number.isNaN(secondsMs)) return null;
  return { secondsMs, fraction: match[2] ?? '' };
}

/**
 * Orders two rows exactly as the server's `(created_at, id)` keyset does, so a
 * gap check agrees with the page the route actually returned.
 *
 * Compares microsecond precision instead of round-tripping through `Date`
 * (which truncates to milliseconds). Fractional digits are compared as padded
 * strings: fractional digits are positional, so "5" and "500000" both mean
 * `.5` and must compare equal. Timestamps outside the server's ISO-with-offset
 * shape fall back to `Date` milliseconds, then the raw string, so ordering
 * stays deterministic instead of silently collapsing.
 */
function compareThreadOrder(a: Pick<Message, 'id' | 'created_at'>, b: Pick<Message, 'id' | 'created_at'>): number {
  const parsedA = parseServerTimestamp(a.created_at);
  const parsedB = parseServerTimestamp(b.created_at);
  if (parsedA && parsedB) {
    if (parsedA.secondsMs !== parsedB.secondsMs) return parsedA.secondsMs - parsedB.secondsMs;
    const fractionA = parsedA.fraction.padEnd(9, '0');
    const fractionB = parsedB.fraction.padEnd(9, '0');
    if (fractionA !== fractionB) return fractionA < fractionB ? -1 : 1;
    return a.id.localeCompare(b.id);
  }
  const at = new Date(a.created_at).getTime();
  const bt = new Date(b.created_at).getTime();
  if (at !== bt) return at - bt;
  if (a.created_at !== b.created_at) return a.created_at < b.created_at ? -1 : 1;
  return a.id.localeCompare(b.id);
}

/** The oldest row of a page, by the same `(created_at, id)` order the server uses. */
function oldestRow<T extends Pick<Message, 'id' | 'created_at'>>(rows: T[]): T | null {
  if (rows.length === 0) return null;
  let oldest = rows[0];
  for (const row of rows) {
    if (compareThreadOrder(row, oldest) < 0) oldest = row;
  }
  return oldest;
}

/** The newest row of a page, by the same `(created_at, id)` order the server uses. */
function newestRow<T extends Pick<Message, 'id' | 'created_at'>>(rows: T[]): T | null {
  if (rows.length === 0) return null;
  let newest = rows[0];
  for (const row of rows) {
    if (compareThreadOrder(row, newest) > 0) newest = row;
  }
  return newest;
}

/**
 * Whether a resync still overlaps the rows the client already holds.
 *
 * Overlap means the resynced page's oldest row is at or before the newest row we
 * hold: the resync reaches down into (or past) the held range, so the rows that
 * fall out of the replaced page can be folded into the retained history and the
 * displayed list stays contiguous.
 *
 * Complete non-overlap means the resynced page starts strictly AFTER everything
 * we hold — more than a page arrived while disconnected. The range in between
 * was never received, so folding the held rows above the resynced page would
 * strand that hole forever: `loadOlderMessages` only pages below the OLDEST
 * displayed row. Callers must drop the retained history and reset the prepend
 * anchor, so the top-reached path refills from the resynced boundary.
 *
 * An empty side counts as overlap: there is nothing to fold against, so callers
 * keep their existing behaviour.
 */
export function resyncKeepsHistory<T extends Pick<Message, 'id' | 'created_at'>>(
  previousPage: T[],
  resyncedPage: Pick<Message, 'id' | 'created_at'>[],
): boolean {
  const previousNewest = newestRow(previousPage);
  const resyncedOldest = oldestRow(resyncedPage);
  if (!previousNewest || !resyncedOldest) return true;
  return compareThreadOrder(resyncedOldest, previousNewest) <= 0;
}

/**
 * Rows from the previously loaded newest page that the resynced page no longer
 * contains and that must stay displayed.
 *
 * `handleMessagesLoaded` REPLACES the parent's newest page, and that page can
 * be LONGER than a server page because `handleNewMessage` appends realtime
 * rows. So after a disconnect a resync can jump the page's oldest row forward
 * by as many messages as arrived while the socket was down: those rows fall
 * out of the new page. Dropping them would make them unreachable, because
 * `loadOlderMessages` only pages before `displayMessages[0]` (which is the
 * retained history, above them). Every previous-page row strictly older than
 * the resynced page's oldest row fills the hole. Callers merge these rows into
 * the retained history, deduplicated by id and kept in server order, so the
 * displayed list stays contiguous and the Virtuoso anchor is preserved
 * (drop `firstItemIndex` by the number of rows actually added).
 */
export function resyncTailRows<T extends Pick<Message, 'id' | 'created_at'>>(
  previousPage: T[],
  resyncedPage: Pick<Message, 'id' | 'created_at'>[],
): T[] {
  if (previousPage.length === 0 || resyncedPage.length === 0) return [];

  let resyncedOldest = resyncedPage[0];
  for (const message of resyncedPage) {
    if (compareThreadOrder(message, resyncedOldest) < 0) resyncedOldest = message;
  }

  const seen = new Set<string>(resyncedPage.map((m) => m.id));
  const tail = previousPage
    .filter((message) => compareThreadOrder(message, resyncedOldest) < 0)
    .sort(compareThreadOrder);

  const carried: T[] = [];
  for (const message of tail) {
    if (seen.has(message.id)) continue;
    seen.add(message.id);
    carried.push(message);
  }
  return carried;
}

/** The `firstItemIndex` after prepending `prependedCount` messages. */
export function nextFirstItemIndex(prev: number, prependedCount: number): number {
  return prev - prependedCount;
}

/**
 * Position of a loaded message in the `data` array, or null when it is not
 * loaded. Use with `scrollToIndex`.
 *
 * The position is NOT offset by `firstItemIndex`: that prop only shifts the
 * anchor and the keys, while React Virtuoso's public index props live in data
 * space and are clamped to `data.length - 1` (`Qn`/`Qe` in the installed
 * build). An absolute index near 1,000,000 is therefore clamped to the last
 * item — the scroll would land on the newest message instead of the target.
 */
export function indexOfMessage(items: ThreadItem[], id: string): number | null {
  const position = items.findIndex((item) => item.id === id);
  return position < 0 ? null : position;
}
