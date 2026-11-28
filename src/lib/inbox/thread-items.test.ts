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
  nextFirstItemIndex,
  resyncKeepsHistory,
  resyncTailRows,
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
    expect(buildThreadItems([])).toEqual({ items: [], headerDayAt: null });
  });

  it('emits one item per message and uses the oldest message as the header day', () => {
    const { items, headerDayAt } = buildThreadItems([
      msg('a', DAY1),
      msg('b', DAY1B),
      msg('c', DAY2),
    ]);
    expect(items.map((i) => i.id)).toEqual(['a', 'b', 'c']);
    expect(headerDayAt).toBe(DAY1);
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
    expect(items.map((i) => i.separatorBelowAt)).toEqual([
      null, // a -> b, same day
      DAY2, // b -> c, day boundary, labelled from c's instant
      null, // c -> d, same day
      DAY3, // d -> e, day boundary, labelled from e's instant
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
    // Same oldest instant, so the header text does not even change.
    expect(withOlder.headerDayAt).toBe(first.headerDayAt);
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
    // Only the header (oldest loaded instant) changes; its height is fixed.
    expect(withOlder.headerDayAt).toBe(DAY1);
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

describe('resyncTailRows', () => {
  // Slice-4 review (BLOCKER, round 2): a resync replaces the newest page but
  // keeps the retained history. `handleMessagesLoaded` replaces the parent's
  // page, and that page can be LONGER than a server page because
  // `handleNewMessage` appends realtime rows. So the resolved page's oldest
  // row can jump forward by as many messages as arrived while disconnected.
  // Dropping them would make them unreachable: `loadOlderMessages` only pages
  // before `displayMessages[0]`. The rows that fall out of the resynced page
  // must be carried into the retained history instead.
  //
  // `chain(from, to)` builds an ascending run of one message per second, so a
  // contiguous displayed list is exactly `o{from}..o{to}` with no gaps.
  const BASE_MS = Date.parse('2026-11-27T00:00:00Z');
  function chain(from: number, to: number): Message[] {
    const rows: Message[] = [];
    for (let n = from; n <= to; n += 1) {
      rows.push(msg(`o${n}`, new Date(BASE_MS + n * 1000).toISOString().replace('Z', '+00:00')));
    }
    return rows;
  }

  const PAGE = 50;

  for (const M of [1, 49, 50]) {
    it(`keeps every received message when ${M} message${M === 1 ? '' : 's'} arrived while disconnected`, () => {
      // Retained history ends at o0; the previous newest page is o1..o50 plus
      // M realtime appends; the resync returns only the newest 50.
      const retainedHistory = chain(-3, 0);
      const serverPage = chain(1, PAGE);
      const realtimeAppends = chain(PAGE + 1, PAGE + M);
      const previousPage = [...serverPage, ...realtimeAppends];
      const resyncedPage = previousPage.slice(-PAGE);

      // The pathological shape: the resynced page's oldest row is later than
      // the previous page's oldest row, so rows fell out of the page.
      expect(resyncedPage[0].id).not.toBe(previousPage[0].id);
      // ...but it still overlaps what we hold, so the fold keeps history.
      expect(resyncKeepsHistory(previousPage, resyncedPage)).toBe(true);

      const carried = resyncTailRows(previousPage, resyncedPage);
      const displayed = [...retainedHistory, ...carried, ...resyncedPage];

      // No message the client ever received is missing from the list...
      expect(displayed.map((m) => m.id)).toEqual(
        chain(-3, PAGE + M).map((m) => m.id),
      );
      // ...and the result is one contiguous run with no internal hole.
      expect(displayed.map((m) => m.id)).toEqual([
        ...Array.from({ length: PAGE + M + 4 }, (_, k) => `o${k - 3}`),
      ]);
    });
  }

  // Complete non-overlap: more than a page arrived while disconnected, so the
  // resynced page starts strictly AFTER the newest row we hold. The range in
  // between was never received, and folding the held rows above the resynced
  // page would strand that hole forever: `loadOlderMessages` only pages below
  // the OLDEST displayed row (the carried one), never into the hole. The only
  // contiguous outcome is to drop the retained history and reset the anchor, so
  // the top-reached path refills from the resynced page's own oldest row.
  it('drops retained history and stays contiguous when the resynced page does not overlap', () => {
    const retainedHistory = chain(-3, 0);
    const previousPage = chain(1, PAGE); // 50 rows held
    const resyncedPage = chain(101, 160); // 60 rows, all newer; 51..100 never received

    expect(resyncKeepsHistory(previousPage, resyncedPage)).toBe(false);

    // Component decision: no overlap -> discard retained history, reset the
    // anchor, keep only the resynced page.
    const keptHistory = resyncKeepsHistory(previousPage, resyncedPage)
      ? [...retainedHistory, ...resyncTailRows(previousPage, resyncedPage)]
      : [];
    const displayed = [...keptHistory, ...resyncedPage];

    // Contiguous: one ascending run with no internal hole.
    const ordinals = displayed.map((m) => Number(m.id.slice(1)));
    for (let i = 1; i < ordinals.length; i += 1) {
      expect(ordinals[i]).toBe(ordinals[i - 1] + 1);
    }
    // Nothing held is stranded above an unreachable gap.
    expect(displayed.map((m) => m.id)).toEqual(chain(101, 160).map((m) => m.id));
    // The refill boundary is the resynced page's oldest row.
    expect(displayed[0].id).toBe('o101');
    // Document the bug this replaces: the old fold would carry o1..o50 and
    // leave 51..100 unreachable above the resynced page.
    expect(resyncTailRows(previousPage, resyncedPage).map((m) => m.id)).toEqual(
      chain(1, PAGE).map((m) => m.id),
    );
  });

  // A resync that brings no new messages is a no-op.
  it('carries nothing and keeps history when the resync has no new messages (M = 0)', () => {
    const page = chain(1, PAGE);
    expect(resyncKeepsHistory(page, page)).toBe(true);
    expect(resyncTailRows(page, page)).toEqual([]);
  });

  it('keeps the older row a resynced page still overlaps, preserving the anchor', () => {
    // Genuine overlap: the new page shares o50 with the previous page, and the
    // previous page's older row (o49) must survive the replacement.
    const previousPage = [msg('o49', DAY2), msg('o50', DAY2B)];
    const resyncedPage = [msg('o50', DAY2B), msg('o51', DAY3)];
    expect(resyncTailRows(previousPage, resyncedPage).map((m) => m.id)).toEqual(['o49']);
  });

  it('carries nothing when either side is empty', () => {
    expect(resyncTailRows([], [msg('o1', DAY1)])).toEqual([]);
    expect(resyncTailRows([msg('o1', DAY1)], [])).toEqual([]);
  });

  it('orders by the microseconds the keyset preserves, not truncated milliseconds', () => {
    // Same second and same millisecond; only the microsecond digits differ.
    // Round-tripping through Date collapses them and would tie-break by id,
    // dropping the genuinely older row (id "z" sorts after "a").
    const older = msg('z', '2026-11-27T10:00:00.000001+00:00');
    const newer = msg('a', '2026-11-27T10:00:00.000002+00:00');
    expect(resyncTailRows([older], [newer]).map((m) => m.id)).toEqual(['z']);
  });

  it('returns the carried rows in server order, deduplicated by id', () => {
    const previousPage = [
      msg('o3', DAY3),
      msg('o1', DAY1),
      msg('o2', DAY2),
      msg('o1', DAY1), // duplicate id, same row
    ];
    const resyncedPage = [msg('o9', DAY3)];
    expect(resyncTailRows(previousPage, resyncedPage).map((m) => m.id)).toEqual([
      'o1',
      'o2',
      'o3',
    ]);
  });
});
