// @vitest-environment jsdom
//
// Slice 1: the thread reads each page from GET /api/inbox/messages and seeds the
// signed media map before handing the rows to the parent.
// Slice 3: the day grouping/items memoize on the merged message list.
// Slice 4: the thread is virtualized. jsdom cannot measure items, so Virtuoso
// itself is replaced by a thin double that renders every item and surfaces
// `startReached` on scroll. That double proves OUR wiring — first-page fetch,
// seeding before prepend, the anchor delta, the item model memo, jump-to-index
// and highlight. The real mount/measure/scroll behaviour is the staging
// browser check (T4.4), not something a zero-height jsdom can assert.

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
  // Last props Virtuoso received (anchor + item count).
  virtuosoProps: { firstItemIndex: 0, count: 0 },
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
      context,
    } = props as {
      data?: { id: string }[];
      itemContent?: (index: number, item: { id: string }) => React.ReactNode;
      computeItemKey?: (index: number, item: { id: string }) => React.Key;
      components?: { Header?: React.ComponentType<{ context?: unknown }> };
      startReached?: () => void;
      firstItemIndex?: number;
      context?: unknown;
    };
    hoisted.virtuosoProps = { firstItemIndex, count: data.length };
    ReactModule.useImperativeHandle(ref, () => ({ scrollToIndex: hoisted.scrollToIndex }), []);
    const Header = components?.Header;
    return ReactModule.createElement(
      'div',
      {
        'data-testid': 'virtuoso',
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
  hoisted.virtuosoProps = { firstItemIndex: 0, count: 0 };
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

  it('seeds the older page, prepends it above, and drops the anchor by exactly its size', async () => {
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

    expect(hoisted.virtuosoProps).toEqual({ firstItemIndex: BASE_INDEX, count: 1 });

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
    expect(hoisted.virtuosoProps).toEqual({ firstItemIndex: BASE_INDEX - 1, count: 2 });

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
});
