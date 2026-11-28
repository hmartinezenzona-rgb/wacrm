// @vitest-environment jsdom
//
// Slice 1: the thread reads each page from GET /api/inbox/messages and seeds the
// signed media map before handing the rows to the parent, so the first render
// can paint media without a second signing round-trip.

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
// integration assertion observes. The bubble probe records every render and
// the signed src it can read at that moment.
vi.mock('./message-bubble', async () => {
  const { peekSignedMediaSrc } = await vi.importActual<typeof import('@/lib/storage/signed-media')>(
    '@/lib/storage/signed-media',
  );
  return {
    MessageBubble: ({ message }: { message: Message }) => {
      hoisted.rowIds.push(message.id);
      hoisted.renderCount[message.id] = (hoisted.renderCount[message.id] ?? 0) + 1;
      hoisted.peekAtRender[message.id] = peekSignedMediaSrc(message.media_url);
      return null;
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

beforeEach(() => {
  resetSignedMediaCache();
  hoisted.fetchThreadPage.mockReset();
  hoisted.rowIds.length = 0;
  hoisted.peekAtRender = {};
  hoisted.renderCount = {};
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
      root.render(
        React.createElement(MessageThread, {
          conversation,
          contact: null,
          messages: [] as Message[],
          onMessagesLoaded,
          onNewMessage: vi.fn(),
          onUpdateMessage: vi.fn(),
          onStatusChange: vi.fn(),
          onAssignChange: vi.fn(),
        }),
      );
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

  it('seeds the older page before prepending its rows', async () => {
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
      root.render(
        React.createElement(MessageThread, {
          conversation,
          contact,
          messages: [pageMessage] as Message[],
          onMessagesLoaded: vi.fn(),
          onNewMessage: vi.fn(),
          onUpdateMessage: vi.fn(),
          onStatusChange: vi.fn(),
          onAssignChange: vi.fn(),
        }),
      );
    });
    await flush();

    const scroller = node.querySelector<HTMLDivElement>('.overflow-y-auto');
    expect(scroller).not.toBeNull();
    await act(async () => {
      scroller!.dispatchEvent(new Event('scroll', { bubbles: true }));
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
    // And the older row could read its signed src on its own first render.
    expect(hoisted.rowIds).toContain('m0');
    expect(hoisted.peekAtRender.m0).toBe('https://signed/b');

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
    hoisted.fetchThreadPage.mockResolvedValue({
      messages: [],
      hasMore: false,
      nextCursor: null,
      signed: {},
      expiresIn: 3600,
    });

    const onRefresh = vi.fn();
    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      root.render(
        React.createElement(MessageThread, {
          conversation,
          contact,
          messages: [m1, m2] as Message[],
          onMessagesLoaded: vi.fn(),
          onNewMessage: vi.fn(),
          onUpdateMessage: vi.fn(),
          onStatusChange: vi.fn(),
          onAssignChange: vi.fn(),
          onRefresh,
        }),
      );
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
});
