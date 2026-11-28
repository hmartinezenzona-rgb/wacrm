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
}));

vi.mock('next-intl', () => ({ useTranslations: () => (key: string) => key }));
vi.mock('@/lib/inbox/thread-page', () => ({ fetchThreadPage: hoisted.fetchThreadPage }));
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
vi.mock('./message-bubble', () => ({ MessageBubble: () => null }));
vi.mock('./message-actions', () => ({ MessageActions: () => null }));
vi.mock('./message-composer', () => ({ MessageComposer: () => null, CHAT_MEDIA_BUCKET: 'chat-media' }));
vi.mock('./template-picker', () => ({ TemplatePicker: () => null }));
vi.mock('./ai-thread-banner', () => ({ AiThreadBanner: () => null }));
vi.mock('./not-business-control', () => ({
  NotBusinessBanner: () => null,
  NotBusinessButton: () => null,
}));
vi.mock('@/lib/storage/upload-media', () => ({ deleteAccountMedia: vi.fn() }));
vi.mock('sonner', () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

import type { Conversation, Message } from '@/types';
import { peekSignedMediaSrc, resetSignedMediaCache } from '@/lib/storage/signed-media';
import { MessageThread } from './message-thread';

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
const CONV = '6d1f0b8e-2a34-4c55-8f60-1b2c3d4e5f70';
const STORED = `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${ACCT}/a.jpg`;

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

beforeEach(() => {
  resetSignedMediaCache();
  hoisted.fetchThreadPage.mockReset();
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
});
