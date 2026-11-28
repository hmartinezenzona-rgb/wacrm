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

import { format } from 'date-fns';
import type { Message } from '@/types';

export interface ThreadItem {
  /** Message id; also the stable virtual key. */
  id: string;
  message: Message;
  /** ISO day (`yyyy-MM-dd`) of the NEXT message when it falls on another day. */
  separatorBelow: string | null;
}

export interface ThreadItems {
  items: ThreadItem[];
  /** `yyyy-MM-dd` of the oldest loaded message; rendered in Virtuoso's Header. */
  headerDay: string | null;
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
  if (messages.length === 0) return { items: [], headerDay: null };

  const items: ThreadItem[] = messages.map((message, index) => {
    const day = dayKey(message);
    const next = messages[index + 1];
    const nextDay = next ? dayKey(next) : null;
    return {
      id: message.id,
      message,
      separatorBelow: next && nextDay !== day ? nextDay : null,
    };
  });

  return { items, headerDay: dayKey(messages[0]) };
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
