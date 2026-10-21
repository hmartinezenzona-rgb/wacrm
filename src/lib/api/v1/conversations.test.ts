import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Conversation, Message } from '@/types';

const { signChatMediaUrl } = vi.hoisted(() => ({ signChatMediaUrl: vi.fn() }));
vi.mock('@/lib/storage/chat-media-server', () => ({ signChatMediaUrl }));

import {
  serializeConversation,
  serializeMessage,
  withSignedMedia,
} from './conversations';

describe('serializeConversation', () => {
  it('projects public fields + nested contact/tags and drops internals', () => {
    const conv = {
      id: 'conv1',
      user_id: 'internal-user',
      account_id: 'internal-acct',
      contact_id: 'c1',
      status: 'open',
      last_message_text: 'hi',
      last_message_at: '2026-01-01T00:00:00Z',
      unread_count: 2,
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
      contact: {
        id: 'c1',
        phone: '+1',
        name: 'Jane',
        tags: [{ id: 't1', name: 'vip', color: '#fff' }],
      },
    } as unknown as Conversation;

    const out = serializeConversation(conv);
    expect(out).not.toHaveProperty('user_id');
    expect(out).not.toHaveProperty('account_id');
    expect(out.contact?.tags).toEqual([{ id: 't1', name: 'vip', color: '#fff' }]);
    expect(out.unread_count).toBe(2);
  });
});

describe('serializeMessage', () => {
  it('maps message_id → whatsapp_message_id and derives direction', () => {
    const inbound = {
      id: 'm1',
      conversation_id: 'conv1',
      sender_type: 'customer',
      content_type: 'text',
      content_text: 'hello',
      message_id: 'wamid.123',
      status: 'delivered',
      created_at: '2026-01-01T00:00:00Z',
    } as unknown as Message;
    const outMsg = serializeMessage(inbound);
    expect(outMsg.direction).toBe('inbound');
    expect(outMsg.whatsapp_message_id).toBe('wamid.123');
    expect(outMsg).not.toHaveProperty('message_id');

    const agent = { ...inbound, sender_type: 'agent' } as unknown as Message;
    expect(serializeMessage(agent).direction).toBe('outbound');
  });
});

describe('withSignedMedia', () => {
  const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
  const STORED = `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${ACCT}/1-wa-1.jpg`;
  const base = {
    id: 'm1',
    conversation_id: 'conv1',
    sender_type: 'customer',
    content_type: 'image',
    status: 'delivered',
    created_at: '2026-01-01T00:00:00Z',
  };

  beforeEach(() => signChatMediaUrl.mockReset());

  it('swaps a chat-media media_url for a 1 h signed URL', async () => {
    signChatMediaUrl.mockResolvedValue('https://signed.example/x?token=t');
    const msg = serializeMessage({ ...base, media_url: STORED } as unknown as Message);
    const out = await withSignedMedia(msg, ACCT);
    expect(signChatMediaUrl).toHaveBeenCalledWith(STORED, 3600, ACCT);
    expect(out.media_url).toBe('https://signed.example/x?token=t');
    expect(out.id).toBe('m1');
  });

  it('leaves null and non-chat-media values unchanged without signing', async () => {
    const none = serializeMessage({ ...base, media_url: null } as unknown as Message);
    expect((await withSignedMedia(none, ACCT)).media_url).toBeNull();
    const meta = serializeMessage({ ...base, media_url: '/api/whatsapp/media/9' } as unknown as Message);
    expect((await withSignedMedia(meta, ACCT)).media_url).toBe('/api/whatsapp/media/9');
    expect(signChatMediaUrl).not.toHaveBeenCalled();
  });

  it("drops a media_url that points at another account's object, without signing", async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const msg = serializeMessage({ ...base, media_url: STORED } as unknown as Message);
    const out = await withSignedMedia(msg, '9a8b7c6d-1111-4222-8333-444455556666');
    expect(out.media_url).toBeNull();
    expect(signChatMediaUrl).not.toHaveBeenCalled();
  });
});
