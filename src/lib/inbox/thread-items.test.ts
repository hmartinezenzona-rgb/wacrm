// Slice 4: the prepend-safe item model that backs the virtualized thread.
//
// Items are messages only (one item per message). A day separator belongs
// BELOW the last message of a day, so prepending older messages never moves
// a separator between items: existing items stay deep-equal, and the anchor
// delta is exactly the number of prepended messages.

import { describe, expect, it } from 'vitest';
import type { Message } from '@/types';
import {
  THREAD_FIRST_ITEM_INDEX_BASE,
  buildThreadItems,
  indexOfMessage,
  newestPageLeavesGap,
  nextFirstItemIndex,
} from './thread-items';

function msg(id: string, createdAt: string): Message {
  return {
    id,
    conversation_id: 'conv',
    sender_type: 'customer',
    content_type: 'text',
    content_text: id,
    status: 'delivered',
    created_at: createdAt,
  } as Message;
}

const DAY1 = '2026-11-27T10:00:00.000000+00:00';
const DAY1B = '2026-11-27T11:00:00.000000+00:00';
const DAY2 = '2026-11-28T09:00:00.000000+00:00';
const DAY2B = '2026-11-28T10:00:00.000000+00:00';
const DAY3 = '2026-11-29T09:00:00.000000+00:00';

describe('buildThreadItems', () => {
  it('returns no items and no header for an empty thread', () => {
    expect(buildThreadItems([])).toEqual({ items: [], headerDay: null, headerDayAt: null });
  });

  it('emits one item per message and uses the oldest message as the header day', () => {
    const { items, headerDay } = buildThreadItems([
      msg('a', DAY1),
      msg('b', DAY1B),
      msg('c', DAY2),
    ]);
    expect(items.map((i) => i.id)).toEqual(['a', 'b', 'c']);
    expect(headerDay).toBe('2026-11-27');
  });

  // Slice-4 review: the label must be rendered from the original instant, not
  // from re-parsing the local `yyyy-MM-dd` key as UTC midnight (which shifts
  // the label one day back in UTC-negative zones). The day key stays for
  // grouping only; these fields carry the instant the label needs.
  it('exposes the oldest message instant for the header label', () => {
    const { headerDayAt } = buildThreadItems([msg('a', DAY1), msg('b', DAY1B), msg('c', DAY2)]);
    expect(headerDayAt).toBe(DAY1);
  });

  it('exposes the next-day instant for each separator label', () => {
    const { items } = buildThreadItems([msg('a', DAY1), msg('b', DAY2), msg('c', DAY3)]);
    expect(items.map((i) => i.separatorBelowAt)).toEqual([DAY2, DAY3, null]);
  });

  it('leaves separatorBelowAt null when the next message is on the same day', () => {
    const { items } = buildThreadItems([msg('a', DAY1), msg('b', DAY1B)]);
    expect(items.map((i) => i.separatorBelowAt)).toEqual([null, null]);
  });

  it('renders the separator below the last message of a day, at every day boundary', () => {
    const { items } = buildThreadItems([
      msg('a', DAY1),
      msg('b', DAY1B),
      msg('c', DAY2),
      msg('d', DAY2B),
      msg('e', DAY3),
    ]);
    expect(items.map((i) => i.separatorBelow)).toEqual([
      null, // a -> b, same day
      '2026-11-28', // b -> c, day boundary
      null, // c -> d, same day
      '2026-11-29', // d -> e, day boundary
      null, // e is the last message
    ]);
  });
});

describe('buildThreadItems prepend stability', () => {
  it('leaves existing items deep-equal when older same-day messages are prepended', () => {
    const first = buildThreadItems([msg('c', DAY2), msg('d', DAY2B)]);
    const withOlder = buildThreadItems([
      msg('a', DAY2), // same day, earlier hour
      msg('b', DAY2),
      msg('c', DAY2),
      msg('d', DAY2B),
    ]);
    // c and d keep their exact shape: same day boundary, same separator below.
    expect(withOlder.items.slice(2)).toEqual(first.items);
    // Same oldest day, so the header text does not even change.
    expect(withOlder.headerDay).toBe(first.headerDay);
  });

  it('leaves existing items deep-equal when older other-day messages are prepended', () => {
    const first = buildThreadItems([msg('c', DAY2), msg('d', DAY2B)]);
    const withOlder = buildThreadItems([
      msg('a', DAY1),
      msg('b', DAY1B),
      msg('c', DAY2),
      msg('d', DAY2B),
    ]);
    expect(withOlder.items.slice(2)).toEqual(first.items);
    // Only the header (oldest loaded day) changes; its height is fixed.
    expect(withOlder.headerDay).toBe('2026-11-27');
  });
});

describe('nextFirstItemIndex', () => {
  it('starts at the documented base', () => {
    expect(THREAD_FIRST_ITEM_INDEX_BASE).toBe(1_000_000);
  });

  it('decreases by exactly the number of prepended messages', () => {
    expect(nextFirstItemIndex(THREAD_FIRST_ITEM_INDEX_BASE, 0)).toBe(1_000_000);
    expect(nextFirstItemIndex(THREAD_FIRST_ITEM_INDEX_BASE, 3)).toBe(999_997);
    expect(nextFirstItemIndex(999_997, 50)).toBe(999_947);
  });
});

describe('indexOfMessage', () => {
  // react-virtuoso indexes items in the absolute space: the index it hands to
  // itemContent/computeItemKey/scrollToIndex is the data position plus
  // firstItemIndex (verified against node_modules/react-virtuoso/dist, where
  // items get `index: relativeIndex + firstItemIndex`).
  it('returns the absolute index the library uses, not the array position', () => {
    const { items } = buildThreadItems([msg('a', DAY1), msg('b', DAY1B), msg('c', DAY2)]);
    expect(indexOfMessage(items, 'a', THREAD_FIRST_ITEM_INDEX_BASE)).toBe(1_000_000);
    expect(indexOfMessage(items, 'b', THREAD_FIRST_ITEM_INDEX_BASE)).toBe(1_000_001);
    expect(indexOfMessage(items, 'c', 999_998)).toBe(1_000_000);
  });

  it('returns null for a message that is not loaded', () => {
    const { items } = buildThreadItems([msg('a', DAY1)]);
    expect(indexOfMessage(items, 'missing', THREAD_FIRST_ITEM_INDEX_BASE)).toBeNull();
  });
});

describe('newestPageLeavesGap', () => {
  // Slice-4 review: a resync replaces the newest page but keeps the retained
  // older history. If more than a page arrived while disconnected, the new
  // page starts after the previous page's newest message and the two blocks
  // cannot be stitched — that gap must be detected so history is refetched.
  it('reports a gap when the resynced page starts after the previous newest message', () => {
    const previous = [msg('b', DAY2), msg('c', DAY2B)];
    const resynced = [msg('z', DAY3)]; // strictly newer than c
    expect(newestPageLeavesGap(previous, resynced)).toBe(true);
  });

  it('reports no gap when the resynced page still overlaps the previous page', () => {
    const previous = [msg('b', DAY2), msg('c', DAY2B)];
    const resynced = [msg('c', DAY2B), msg('z', DAY3)]; // shares c
    expect(newestPageLeavesGap(previous, resynced)).toBe(false);
  });

  it('reports no gap when the resynced page reaches back before the previous newest', () => {
    const previous = [msg('c', DAY2B)];
    const resynced = [msg('b', DAY2), msg('c', DAY2B), msg('z', DAY3)];
    expect(newestPageLeavesGap(previous, resynced)).toBe(false);
  });

  it('reports no gap when either side is empty', () => {
    expect(newestPageLeavesGap([], [msg('a', DAY1)])).toBe(false);
    expect(newestPageLeavesGap([msg('a', DAY1)], [])).toBe(false);
  });

  it('orders equal timestamps by id, matching the server keyset', () => {
    const sameInstant = '2026-11-27T10:00:00.000000+00:00';
    expect(newestPageLeavesGap([msg('a', sameInstant)], [msg('b', sameInstant)])).toBe(true);
    expect(newestPageLeavesGap([msg('b', sameInstant)], [msg('a', sameInstant)])).toBe(false);
  });
});
