// Prepend-safe item model for the virtualized thread.
//
// One item per message; day separators live BELOW the last message of a day.
// This is what makes prepending older pages exact: no separator ever moves
// between items, so every already-loaded item keeps its height and its
// identity, and the only anchor change is `firstItemIndex` dropping by the
// number of prepended messages.
//
// The index space is react-virtuoso's absolute one: virt-4x gives each item
// `index = dataPosition + firstItemIndex` and expects the same space in
// `scrollToIndex`/`itemContent`/`computeItemKey`. `indexOfMessage` therefore
// returns `firstItemIndex + position`, never the bare array position.

import { format, isSameDay, subDays } from 'date-fns';
import type { Message } from '@/types';

export interface ThreadItem {
  /** Message id; also the stable virtual key. */
  id: string;
  message: Message;
  /**
   * ISO day (`yyyy-MM-dd`) of the NEXT message when it falls on another day.
   * Grouping only: never parse this back into a Date, because a date-only
   * string reads as UTC midnight and shifts a day back in western zones.
   */
  separatorBelow: string | null;
  /** Original instant of the NEXT message when it falls on another day; the label source. */
  separatorBelowAt: string | null;
}

export interface ThreadItems {
  items: ThreadItem[];
  /** `yyyy-MM-dd` of the oldest loaded message. Grouping only. */
  headerDay: string | null;
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

/** Build the thread item list and the oldest-day header key. */
export function buildThreadItems(messages: Message[]): ThreadItems {
  if (messages.length === 0) return { items: [], headerDay: null, headerDayAt: null };

  const items: ThreadItem[] = messages.map((message, index) => {
    const day = dayKey(message);
    const next = messages[index + 1];
    const nextDay = next ? dayKey(next) : null;
    const boundary = !!(next && nextDay !== day);
    return {
      id: message.id,
      message,
      separatorBelow: boundary ? nextDay : null,
      separatorBelowAt: boundary ? next!.created_at : null,
    };
  });

  return {
    items,
    headerDay: dayKey(messages[0]),
    headerDayAt: messages[0].created_at,
  };
}

/**
 * Orders two rows exactly as the server's `(created_at, id)` keyset does, so a
 * gap check agrees with the page the route actually returned.
 */
function compareThreadOrder(a: Pick<Message, 'id' | 'created_at'>, b: Pick<Message, 'id' | 'created_at'>): number {
  const at = new Date(a.created_at).getTime();
  const bt = new Date(b.created_at).getTime();
  if (at !== bt) return at - bt;
  return a.id.localeCompare(b.id);
}

/**
 * True when a resynced newest page cannot be joined to the previously loaded
 * newest page: it starts strictly after that page's newest message, so anything
 * between them was never fetched. `loadOlderMessages` only pages before the
 * FIRST displayed message, so such a hole would be unreachable; callers must
 * drop the retained history and refetch from the resynced page's boundary.
 */
export function newestPageLeavesGap(
  previousPage: Pick<Message, 'id' | 'created_at'>[],
  resyncedPage: Pick<Message, 'id' | 'created_at'>[],
): boolean {
  if (previousPage.length === 0 || resyncedPage.length === 0) return false;

  let previousNewest = previousPage[0];
  for (const message of previousPage) {
    if (compareThreadOrder(message, previousNewest) > 0) previousNewest = message;
  }

  let resyncedOldest = resyncedPage[0];
  for (const message of resyncedPage) {
    if (compareThreadOrder(message, resyncedOldest) < 0) resyncedOldest = message;
  }

  return compareThreadOrder(resyncedOldest, previousNewest) > 0;
}

/** The `firstItemIndex` after prepending `prependedCount` messages. */
export function nextFirstItemIndex(prev: number, prependedCount: number): number {
  return prev - prependedCount;
}

/**
 * Absolute Virtuoso index of a loaded message, or null when it is not loaded.
 * Use with `scrollToIndex` and `computeItemKey`.
 */
export function indexOfMessage(
  items: ThreadItem[],
  id: string,
  firstItemIndex: number,
): number | null {
  const position = items.findIndex((item) => item.id === id);
  if (position < 0) return null;
  return firstItemIndex + position;
}
