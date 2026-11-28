// @vitest-environment jsdom
//
// Slice 1: the thread reads each page from GET /api/inbox/messages and seeds the
// signed media map before handing the rows to the parent.
// Slice 3: the day grouping/items memoize on the merged message list.
// Slice 4: the thread is virtualized. jsdom cannot measure items, so Virtuoso
// itself is replaced by a thin double that renders every item and surfaces
// `startReached` on scroll. That double proves OUR wiring — first-page fetch,
// seeding before prepend, the anchor delta, the item model memo, jump-to-index
// and highlight. It cannot prove the real layout conditions: top-reached
// detection, open-at-bottom, prepend re-anchoring without a visual jump,
// follow-the-tail while at the bottom, and resync keeping the scroll position.
// Those remain the staging browser check (T4.4).

import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const hoisted = vi.hoisted(() => ({
  fetchThreadPage: vi.fn(),
  supabase: {} as Record<string, unknown>,
  rowIds: [] as string[],
  peekAtRender: {} as Record<string, string | null>,
  renderCount: {} as Record<string, number>,
  translate: (key: string) => key,
  // Counts buildThreadItems runs. Slice 4 memoizes the item model on the
  // merged message list, so an unrelated render must not rebuild it.
  buildCalls: 0,
  // Last props Virtuoso received (anchor, item count, follow policy).
  virtuosoProps: {
    firstItemIndex: 0,
    count: 0,
    followOutput: undefined as ((isAtBottom: boolean) => unknown) | undefined,
  },
  // One entry per Virtuoso render, so a test can prove `itemContent` keeps its
  // identity across unrelated re-renders.
  itemContentRefs: [] as unknown[],
  scrollToIndex: vi.fn(),
}));

// One stable translator: a fresh function per render would make the thread's
// `useCallback` chains (and therefore every row's props) change identity, and
// the memoization assertion would test the mock instead of the wiring.
vi.mock('next-intl', () => ({ useTranslations: () => hoisted.translate }));
vi.mock('@/lib/inbox/thread-page', async () => {
  const actual = await vi.importActual<typeof import('@/lib/inbox/thread-page')>(
    '@/lib/inbox/thread-page',
  );
  return { ...actual, fetchThreadPage: hoisted.fetchThreadPage };
});
vi.mock('@/lib/inbox/thread-items', async () => {
  const actual = await vi.importActual<typeof import('@/lib/inbox/thread-items')>(
    '@/lib/inbox/thread-items',
  );
  return {
    ...actual,
    buildThreadItems: (messages: Parameters<typeof actual.buildThreadItems>[0]) => {
      hoisted.buildCalls += 1;
      return actual.buildThreadItems(messages);
    },
  };
});
// Virtuoso double: renders every item, records the anchor, and calls
// `startReached` when the test scrolls its surface.
vi.mock('react-virtuoso', async () => {
  const ReactModule = await import('react');
  type AnyProps = Record<string, unknown> & { context?: unknown };
  const Virtuoso = ReactModule.forwardRef(function VirtuosoMock(props: AnyProps, ref: React.ForwardedRef<unknown>) {
    const {
      data = [],
      itemContent,
      computeItemKey,
      components,
      startReached,
      firstItemIndex = 0,
      followOutput,
      context,
    } = props as {
      data?: { id: string }[];
      itemContent?: (index: number, item: { id: string }) => React.ReactNode;
      computeItemKey?: (index: number, item: { id: string }) => React.Key;
      components?: { Header?: React.ComponentType<{ context?: unknown }> };
      startReached?: () => void;
      firstItemIndex?: number;
      followOutput?: (isAtBottom: boolean) => unknown;
      context?: unknown;
    };
    hoisted.virtuosoProps = { firstItemIndex, count: data.length, followOutput };
    hoisted.itemContentRefs.push(itemContent);
    ReactModule.useImperativeHandle(ref, () => ({ scrollToIndex: hoisted.scrollToIndex }), []);
    const Header = components?.Header;
    return ReactModule.createElement(
      'div',
      {
        'data-testid': 'virtuoso',
        // HONESTY NOTE: this double calls `startReached` on ANY scroll. It
        // proves our wiring (a scroll asks for the older page), NOT the real
        // "reached the top" condition Virtuoso computes from measured layout.
        onScroll: () => {
          void startReached?.();
        },
      },
      Header ? ReactModule.createElement(Header, { context }) : null,
      data.map((item, i) => {
        const key = computeItemKey ? computeItemKey(firstItemIndex + i, item) : i;
        return ReactModule.createElement(
          ReactModule.Fragment,
          { key },
          itemContent?.(firstItemIndex + i, item),
        );
      }),
    );
  });
  return { Virtuoso };
});
vi.mock('@/lib/supabase/client', () => ({ createClient: () => hoisted.supabase }));
vi.mock('@/hooks/use-auth', () => ({ useAuth: () => ({ user: { id: 'u1' } }) }));
vi.mock('@/hooks/use-presence', () => ({
  usePresence: () => ({ getPresence: () => null, getRow: () => undefined, now: Date.now() }),
}));
vi.mock('@/lib/presence', () => ({ presenceLabel: () => '' }));
vi.mock('@/components/contacts/contact-avatar', () => ({ ContactAvatar: () => null }));
vi.mock('@/components/presence/presence-dot', () => ({ PresenceDot: () => null }));
vi.mock('@/components/ui/badge', () => ({ Badge: () => null }));
vi.mock('@/components/ui/dropdown-menu', () => ({
  DropdownMenu: () => null,
  DropdownMenuContent: () => null,
  DropdownMenuItem: () => null,
  DropdownMenuSeparator: () => null,
  DropdownMenuTrigger: () => null,
}));
vi.mock('@/components/ui/scroll-area', () => ({
  ScrollArea: ({ children }: { children?: React.ReactNode }) => React.createElement('div', null, children),
}));
// The real ThreadRow is rendered (no mock), so its memo contract is what the
// integration assertion observes. The bubble probe records every render, the
// signed src it can read at that moment, and exposes the quote-jump click.
vi.mock('./message-bubble', async () => {
  const ReactModule = await import('react');
  const { peekSignedMediaSrc } = await vi.importActual<typeof import('@/lib/storage/signed-media')>(
    '@/lib/storage/signed-media',
  );
  return {
    MessageBubble: ({ message, onJumpToReply }: {
      message: { id: string; media_url?: string | null };
      onJumpToReply?: () => void;
    }) => {
      hoisted.rowIds.push(message.id);
      hoisted.renderCount[message.id] = (hoisted.renderCount[message.id] ?? 0) + 1;
      hoisted.peekAtRender[message.id] = peekSignedMediaSrc(message.media_url);
      return ReactModule.createElement(
        'button',
        {
          'data-testid': `jump-${message.id}`,
          onClick: onJumpToReply,
        },
        message.id,
      );
    },
  };
});
vi.mock('./message-actions', () => ({
  MessageActions: ({ children }: { children?: React.ReactNode }) =>
    React.createElement(React.Fragment, null, children),
}));
vi.mock('./message-composer', () => ({ MessageComposer: () => null, CHAT_MEDIA_BUCKET: 'chat-media' }));
vi.mock('./template-picker', () => ({ TemplatePicker: () => null }));
vi.mock('./ai-thread-banner', () => ({ AiThreadBanner: () => null }));
vi.mock('./not-business-control', () => ({
  NotBusinessBanner: () => null,
  NotBusinessButton: () => null,
}));
vi.mock('@/lib/storage/upload-media', () => ({ deleteAccountMedia: vi.fn() }));
vi.mock('sonner', () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

import type { Contact, Conversation, Message } from '@/types';
import { peekSignedMediaSrc, resetSignedMediaCache } from '@/lib/storage/signed-media';
import { MessageThread } from './message-thread';

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
const CONV = '6d1f0b8e-2a34-4c55-8f60-1b2c3d4e5f70';
const STORED = `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${ACCT}/a.jpg`;
const STORED_OLDER = `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${ACCT}/b.jpg`;
const BASE_INDEX = 1_000_000;

function chainable(result: unknown) {
  const query: Record<string, unknown> = {};
  for (const method of ['select', 'update', 'eq', 'or', 'order', 'limit']) {
    query[method] = vi.fn(() => query);
  }
  query.then = (onFulfilled: (value: unknown) => unknown, onRejected: (reason: unknown) => unknown) =>
    Promise.resolve(result).then(onFulfilled, onRejected);
  return query;
}

const pageMessage = {
  id: 'm1',
  conversation_id: CONV,
  sender_type: 'customer',
  content_type: 'image',
  status: 'delivered',
  created_at: '2026-11-27T10:00:01.123456+00:00',
  media_url: STORED,
} as Message;

const conversation = {
  id: CONV,
  contact_id: 'c1',
  status: 'open',
  unread_count: 0,
} as unknown as Conversation;

const contact = {
  id: 'c1',
  phone: '+13055550100',
  full_name: 'Ada',
  avatar_url: null,
  avatar_gender: null,
  avatar_seq: null,
} as unknown as Contact;

const emptyPage = {
  messages: [] as Message[],
  hasMore: false,
  nextCursor: null,
  signed: {},
  expiresIn: 3600,
};

beforeEach(() => {
  resetSignedMediaCache();
  hoisted.fetchThreadPage.mockReset();
  hoisted.scrollToIndex.mockReset();
  hoisted.rowIds.length = 0;
  hoisted.peekAtRender = {};
  hoisted.renderCount = {};
  hoisted.buildCalls = 0;
  hoisted.virtuosoProps = { firstItemIndex: 0, count: 0, followOutput: undefined };
  hoisted.itemContentRefs.length = 0;
  hoisted.supabase = {
    from: vi.fn(() => chainable({ data: [], error: null })),
    channel: vi.fn(() => {
      const channel: Record<string, unknown> = {};
      channel.on = vi.fn(() => channel);
      channel.subscribe = vi.fn(() => channel);
      return channel;
    }),
    removeChannel: vi.fn(),
  };
});

afterEach(() => {
  vi.clearAllMocks();
  resetSignedMediaCache();
});

async function flush() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

function renderThread(node: HTMLElement, root: ReturnType<typeof createRoot>, props: Record<string, unknown>) {
  return root.render(
    React.createElement(MessageThread, {
      conversation,
      contact,
      messages: [] as Message[],
      onMessagesLoaded: vi.fn(),
      onNewMessage: vi.fn(),
      onUpdateMessage: vi.fn(),
      onStatusChange: vi.fn(),
      onAssignChange: vi.fn(),
      ...props,
    } as never),
  );
}

describe('MessageThread thread page', () => {
  it('requests the first page once and seeds the signed map before loading rows', async () => {
    hoisted.fetchThreadPage.mockResolvedValue({
      messages: [pageMessage],
      hasMore: true,
      nextCursor: { createdAt: pageMessage.created_at, id: pageMessage.id },
      signed: { [STORED]: 'https://signed/a' },
      expiresIn: 3600,
    });

    let peekedInsideLoad: string | null = null;
    const onMessagesLoaded = vi.fn(() => {
      peekedInsideLoad = peekSignedMediaSrc(STORED);
    });

    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      renderThread(node, root, { contact: null, onMessagesLoaded });
    });
    await flush();

    expect(hoisted.fetchThreadPage).toHaveBeenCalledTimes(1);
    expect(hoisted.fetchThreadPage).toHaveBeenCalledWith(CONV, undefined, 50);
    expect(onMessagesLoaded).toHaveBeenCalledTimes(1);
    expect(onMessagesLoaded).toHaveBeenCalledWith([pageMessage]);
    // The seeded map was already readable when the parent received the rows.
    expect(peekedInsideLoad).toBe('https://signed/a');

    await act(async () => root.unmount());
  });

  // HONESTY (slice-4 review): the double fires `startReached` on any scroll, so
  // this test proves the wiring — fetch-before-prepend, seeding, and the anchor
  // delta — not the real layout condition "the surface actually reached the
  // top". Open-at-bottom, the true top-reached trigger, the no-jump re-anchor
  // and jump centring stay staging-only (T4.4).
  it('wires a scroll to fetch and prepend a seeded older page (layout condition not exercised)', async () => {
    const olderMessage = {
      ...pageMessage,
      id: 'm0',
      created_at: '2026-11-27T09:00:00.000000+00:00',
      media_url: STORED_OLDER,
    } as Message;

    hoisted.fetchThreadPage
      .mockResolvedValueOnce({
        messages: [pageMessage],
        hasMore: true,
        nextCursor: { createdAt: pageMessage.created_at, id: pageMessage.id },
        signed: { [STORED]: 'https://signed/a' },
        expiresIn: 3600,
      })
      .mockResolvedValueOnce({
        messages: [olderMessage],
        hasMore: false,
        nextCursor: null,
        signed: { [STORED_OLDER]: 'https://signed/b' },
        expiresIn: 3600,
      });

    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      renderThread(node, root, { messages: [pageMessage] as Message[] });
    });
    await flush();

    expect(hoisted.virtuosoProps).toMatchObject({ firstItemIndex: BASE_INDEX, count: 1 });

    // Reaching the top asks for the page before the oldest loaded message.
    const surface = node.querySelector<HTMLDivElement>('[data-testid="virtuoso"]');
    expect(surface).not.toBeNull();
    await act(async () => {
      surface!.dispatchEvent(new Event('scroll', { bubbles: true }));
    });
    await flush();

    expect(hoisted.fetchThreadPage).toHaveBeenCalledTimes(2);
    expect(hoisted.fetchThreadPage).toHaveBeenLastCalledWith(
      CONV,
      { createdAt: pageMessage.created_at, id: pageMessage.id },
      50,
    );
    // The signed map arrived and was cached before the parent could prepend.
    expect(peekSignedMediaSrc(STORED_OLDER)).toBe('https://signed/b');
    // The older row rendered with its own signed src on its first render.
    expect(hoisted.peekAtRender.m0).toBe('https://signed/b');
    // Older item first, and no jump: the anchor dropped by exactly one.
    const order = Array.from(node.querySelectorAll('[data-message-id]')).map((el) =>
      el.getAttribute('data-message-id'),
    );
    expect(order).toEqual(['m0', 'm1']);
    expect(hoisted.virtuosoProps).toMatchObject({ firstItemIndex: BASE_INDEX - 1, count: 2 });

    await act(async () => root.unmount());
  });

  it('an unrelated parent state change leaves untouched rows unrendered', async () => {
    const m1 = {
      ...pageMessage,
      id: 'm1',
      content_type: 'text',
      media_url: undefined,
      created_at: '2026-11-27T10:00:01.000000+00:00',
    } as Message;
    const m2 = {
      ...pageMessage,
      id: 'm2',
      content_type: 'text',
      media_url: undefined,
      created_at: '2026-11-27T10:00:02.000000+00:00',
    } as Message;
    hoisted.fetchThreadPage.mockResolvedValue(emptyPage);

    const onRefresh = vi.fn();
    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      renderThread(node, root, { messages: [m1, m2] as Message[], onRefresh });
    });
    await flush();
    expect(hoisted.renderCount).toEqual({ m1: 1, m2: 1 });

    // The manual-refresh click flips `isRefreshing` in the thread only.
    const refresh = node.querySelector<HTMLButtonElement>(
      'button[aria-label="refreshConversation"]',
    );
    expect(refresh).not.toBeNull();
    await act(async () => {
      refresh!.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
    await flush();

    expect(onRefresh).toHaveBeenCalledTimes(1);
    // Neither row's props changed, so neither row may re-render.
    expect(hoisted.renderCount).toEqual({ m1: 1, m2: 1 });

    await act(async () => root.unmount());
  });

  it('reuses the item model when the message list did not change', async () => {
    const g1 = {
      ...pageMessage,
      id: 'g1',
      content_type: 'text',
      media_url: undefined,
      created_at: '2020-01-01T10:00:00.000000+00:00',
    } as Message;
    const g2 = {
      ...pageMessage,
      id: 'g2',
      content_type: 'text',
      media_url: undefined,
      created_at: '2020-01-02T10:00:00.000000+00:00',
    } as Message;
    const g3 = {
      ...pageMessage,
      id: 'g3',
      content_type: 'text',
      media_url: undefined,
      created_at: '2020-01-02T11:00:00.000000+00:00',
    } as Message;
    hoisted.fetchThreadPage.mockResolvedValue(emptyPage);

    const onRefresh = vi.fn();
    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      renderThread(node, root, { messages: [g1, g2] as Message[], onRefresh });
    });
    await flush();
    const buildsAfterMount = hoisted.buildCalls;
    expect(buildsAfterMount).toBeGreaterThan(0);

    // An unrelated state change (the refresh spinner) must not rebuild items.
    const refresh = node.querySelector<HTMLButtonElement>(
      'button[aria-label="refreshConversation"]',
    );
    await act(async () => {
      refresh!.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
    await flush();
    expect(hoisted.buildCalls).toBe(buildsAfterMount);

    // A real list change rebuilds it once.
    await act(async () => {
      renderThread(node, root, { messages: [g1, g2, g3] as Message[], onRefresh });
    });
    await flush();
    expect(hoisted.buildCalls).toBe(buildsAfterMount + 1);

    await act(async () => root.unmount());
  });

  it('jumps by absolute Virtuoso index and highlights the target', async () => {
    const target = {
      ...pageMessage,
      id: 'A',
      content_type: 'text',
      media_url: undefined,
      created_at: '2026-11-27T10:00:00.000000+00:00',
    } as Message;
    const reply = {
      ...pageMessage,
      id: 'B',
      content_type: 'text',
      media_url: undefined,
      created_at: '2026-11-27T10:00:05.000000+00:00',
      reply_to_message_id: 'A',
    } as Message;
    hoisted.fetchThreadPage.mockResolvedValue(emptyPage);

    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      renderThread(node, root, { messages: [target, reply] as Message[] });
    });
    await flush();

    const jump = node.querySelector<HTMLButtonElement>('[data-testid="jump-B"]');
    expect(jump).not.toBeNull();
    await act(async () => {
      jump!.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
    await flush();

    // A is at data position 0, so its absolute index is the anchor base.
    expect(hoisted.scrollToIndex).toHaveBeenCalledWith({
      index: BASE_INDEX,
      align: 'center',
      behavior: 'smooth',
    });
    const rowA = node.querySelector('[data-message-id="A"]');
    expect(rowA?.className).toContain('ring-2');

    await act(async () => root.unmount());
  });

  // Slice-4 review (should-fix): the spec says the view stays anchored unless
  // the agent was already at the bottom. This asserts the policy we hand
  // Virtuoso; the real scroll behaviour on a measured list is staging-only.
  it('follows the tail only when the agent is already at the bottom', async () => {
    hoisted.fetchThreadPage.mockResolvedValue(emptyPage);
    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      renderThread(node, root, { messages: [pageMessage] as Message[] });
    });
    await flush();

    const follow = hoisted.virtuosoProps.followOutput;
    expect(typeof follow).toBe('function');
    expect(follow!(true)).toBe('auto');
    expect(follow!(false)).toBe(false);

    await act(async () => root.unmount());
  });

  // Slice-4 review (should-fix): a fresh inline arrow per render defeats
  // Virtuoso's item memoization.
  it('keeps itemContent identity-stable across unrelated re-renders', async () => {
    hoisted.fetchThreadPage.mockResolvedValue(emptyPage);
    const onRefresh = vi.fn();
    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      renderThread(node, root, { messages: [pageMessage] as Message[], onRefresh });
    });
    await flush();
    const before = hoisted.itemContentRefs[hoisted.itemContentRefs.length - 1];
    expect(before).toBeTypeOf('function');

    const refresh = node.querySelector<HTMLButtonElement>(
      'button[aria-label="refreshConversation"]',
    );
    await act(async () => {
      refresh!.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
    await flush();

    const after = hoisted.itemContentRefs[hoisted.itemContentRefs.length - 1];
    expect(after).toBe(before);

    await act(async () => root.unmount());
  });

  // Slice-4 review (BLOCKER, round 2): a resync that skips past the retained
  // history must NOT drop rows the client already received — `loadOlderMessages`
  // only pages before the FIRST displayed message, so dropping them loses them
  // forever. The rows that fall out of the resynced page are carried into the
  // retained history, the list stays contiguous, and the anchor only moves by
  // the number of rows actually added.
  it('carries the previous page tail into history when a resync skips past it', async () => {
    const at = (id: string, createdAt: string) =>
      ({ ...pageMessage, id, content_type: 'text', media_url: undefined, created_at: createdAt }) as Message;
    const retained = at('r1', '2026-11-27T09:00:00.000000+00:00');
    const previousNewest = at('r2', '2026-11-27T10:00:00.000000+00:00');
    const resynced = at('r9', '2026-11-27T20:00:00.000000+00:00');

    hoisted.fetchThreadPage
      .mockResolvedValueOnce({
        messages: [previousNewest],
        hasMore: true,
        nextCursor: { createdAt: previousNewest.created_at, id: 'r2' },
        signed: {},
        expiresIn: 3600,
      })
      .mockResolvedValueOnce({
        messages: [retained],
        hasMore: false,
        nextCursor: null,
        signed: {},
        expiresIn: 3600,
      })
      .mockResolvedValueOnce({
        messages: [resynced],
        hasMore: true,
        nextCursor: { createdAt: resynced.created_at, id: 'r9' },
        signed: {},
        expiresIn: 3600,
      });

    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      renderThread(node, root, { messages: [previousNewest] as Message[] });
    });
    await flush();

    // Load the retained older page.
    await act(async () => {
      node
        .querySelector<HTMLDivElement>('[data-testid="virtuoso"]')!
        .dispatchEvent(new Event('scroll', { bubbles: true }));
    });
    await flush();
    expect(hoisted.virtuosoProps).toMatchObject({ firstItemIndex: BASE_INDEX - 1, count: 2 });

    // Resync returns a page that starts AFTER the previous newest message, so
    // more than a page arrived while disconnected. The parent's messages prop
    // is still the old page at this point — that is the real sequence.
    await act(async () => {
      renderThread(node, root, { messages: [previousNewest] as Message[], resyncToken: 1 });
    });
    await flush();
    // Now the parent applies the resynced page (what onMessagesLoaded does).
    await act(async () => {
      renderThread(node, root, { messages: [resynced] as Message[], resyncToken: 1 });
    });
    await flush();

    // r2 fell out of the resynced page and was folded above it: nothing the
    // client received is lost, and the anchor moved by exactly that one row.
    expect(hoisted.virtuosoProps).toMatchObject({ firstItemIndex: BASE_INDEX - 2, count: 3 });
    expect(hoisted.rowIds).toContain('r1');
    expect(hoisted.rowIds).toContain('r2');
    expect(hoisted.rowIds).toContain('r9');

    await act(async () => root.unmount());
  });

  it('keeps retained history when the resynced page still overlaps it', async () => {
    const at = (id: string, createdAt: string) =>
      ({ ...pageMessage, id, content_type: 'text', media_url: undefined, created_at: createdAt }) as Message;
    const retained = at('o1', '2026-11-27T09:00:00.000000+00:00');
    const previousNewest = at('o2', '2026-11-27T10:00:00.000000+00:00');
    const overlapNewest = at('o3', '2026-11-27T11:00:00.000000+00:00');

    hoisted.fetchThreadPage
      .mockResolvedValueOnce({
        messages: [previousNewest],
        hasMore: true,
        nextCursor: { createdAt: previousNewest.created_at, id: 'o2' },
        signed: {},
        expiresIn: 3600,
      })
      .mockResolvedValueOnce({
        messages: [retained],
        hasMore: false,
        nextCursor: null,
        signed: {},
        expiresIn: 3600,
      })
      .mockResolvedValueOnce({
        messages: [previousNewest, overlapNewest],
        hasMore: false,
        nextCursor: null,
        signed: {},
        expiresIn: 3600,
      });

    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      renderThread(node, root, { messages: [previousNewest] as Message[] });
    });
    await flush();
    await act(async () => {
      node
        .querySelector<HTMLDivElement>('[data-testid="virtuoso"]')!
        .dispatchEvent(new Event('scroll', { bubbles: true }));
    });
    await flush();
    expect(hoisted.virtuosoProps).toMatchObject({ firstItemIndex: BASE_INDEX - 1, count: 2 });

    await act(async () => {
      renderThread(node, root, { messages: [previousNewest] as Message[], resyncToken: 1 });
    });
    await flush();
    await act(async () => {
      renderThread(node, root, {
        messages: [previousNewest, overlapNewest] as Message[],
        resyncToken: 1,
      });
    });
    await flush();

    // Overlap means no hole: the retained page stays and the new one joins it.
    expect(hoisted.virtuosoProps).toMatchObject({ firstItemIndex: BASE_INDEX - 1, count: 3 });

    await act(async () => root.unmount());
  });

  // Slice-4 review (BLOCKER): under a UTC-negative zone the old path parsed
  // the local day key as UTC midnight and rendered every label one day early.
  // The header and the in-flow separator must both come from the instant.
  it('labels the header and separators by local day in a UTC-negative zone', async () => {
    const previousTz = process.env.TZ;
    process.env.TZ = 'America/Havana';
    try {
      const now = new Date();
      const m1 = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 1, 0, 0);
      const m2 = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 1, 0, 0);
      const asMessage = (id: string, date: Date) =>
        ({ ...pageMessage, id, content_type: 'text', media_url: undefined, created_at: date.toISOString() }) as Message;

      hoisted.fetchThreadPage.mockResolvedValue(emptyPage);
      const node = document.createElement('div');
      const root = createRoot(node);
      await act(async () => {
        renderThread(node, root, { messages: [asMessage('t1', m1), asMessage('t2', m2)] });
      });
      await flush();

      const labels = Array.from(node.querySelectorAll('span.rounded-full')).map(
        (el) => el.textContent,
      );
      // Header = oldest message's local day (today); separator below t1 = the
      // next message's local day. Pre-fix these read "yesterday" and "today".
      expect(labels[0]).toBe('today');
      expect(labels[1]).toBe(
        new Intl.DateTimeFormat('en-US', { month: 'long', day: 'numeric', year: 'numeric' }).format(m2),
      );

      await act(async () => root.unmount());
    } finally {
      if (previousTz === undefined) delete process.env.TZ;
      else process.env.TZ = previousTz;
    }
  });
});
