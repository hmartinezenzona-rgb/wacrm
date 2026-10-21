import { describe, expect, it } from 'vitest';

import {
  isChatMediaUrl,
  parseChatMediaPath,
  toChatMediaSrc,
} from './chat-media';

const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
const PATH = `account-${ACCT}/1700000000000-wa-123.jpg`;
const PUBLIC = `https://abc.supabase.co/storage/v1/object/public/chat-media/${PATH}`;

describe('parseChatMediaPath', () => {
  it('reads the path from the public URL shape', () => {
    expect(parseChatMediaPath(PUBLIC)).toBe(PATH);
  });

  it('reads the path from a signed URL, ignoring the token', () => {
    const signed = `https://abc.supabase.co/storage/v1/object/sign/chat-media/${PATH}?token=eyJ.x.y`;
    expect(parseChatMediaPath(signed)).toBe(PATH);
  });

  it('reads the path from the same-origin proxy shape (relative and absolute)', () => {
    expect(parseChatMediaPath(`/api/chat-media/${PATH}`)).toBe(PATH);
    expect(parseChatMediaPath(`https://app.example.com/api/chat-media/${PATH}`)).toBe(PATH);
  });

  it('decodes percent-encoded segments', () => {
    const p = `account-${ACCT}/1-wa-1%20x.jpg`;
    expect(parseChatMediaPath(`/api/chat-media/${p}`)).toBe(`account-${ACCT}/1-wa-1 x.jpg`);
  });

  it('returns null for other buckets, other hosts shapes and non-URLs', () => {
    expect(
      parseChatMediaPath(`https://abc.supabase.co/storage/v1/object/public/avatars/${PATH}`),
    ).toBeNull();
    expect(parseChatMediaPath('/api/whatsapp/media/123')).toBeNull();
    expect(parseChatMediaPath('https://example.com/a.png')).toBeNull();
    expect(parseChatMediaPath('')).toBeNull();
    expect(parseChatMediaPath(null)).toBeNull();
    expect(parseChatMediaPath(undefined)).toBeNull();
  });

  it('refuses traversal, backslashes, empty segments and foreign folders', () => {
    const bad = [
      `account-${ACCT}/../account-${ACCT}/x.jpg`,
      `account-${ACCT}/%2e%2e/x.jpg`,
      `account-${ACCT}/a%5Cb.jpg`,
      `account-${ACCT}//x.jpg`,
      `account-${ACCT}/./x.jpg`,
      `account-${ACCT}`,
      `${ACCT}/x.jpg`,
      `account-not-a-uuid/x.jpg`,
      `other/x.jpg`,
      `account-${ACCT}/%E0%A4%A.jpg`,
    ];
    for (const p of bad) {
      expect(parseChatMediaPath(`/api/chat-media/${p}`), p).toBeNull();
      expect(
        parseChatMediaPath(`https://abc.supabase.co/storage/v1/object/public/chat-media/${p}`),
        p,
      ).toBeNull();
    }
  });
});

describe('toChatMediaSrc', () => {
  it('maps a public chat-media URL to the proxy', () => {
    expect(toChatMediaSrc(PUBLIC)).toBe(`/api/chat-media/${PATH}`);
  });

  it('encodes each segment', () => {
    const stored = `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${ACCT}/1-wa-1%20x%23.jpg`;
    expect(toChatMediaSrc(stored)).toBe(`/api/chat-media/account-${ACCT}/1-wa-1%20x%23.jpg`);
  });

  it('is idempotent on the proxy shape', () => {
    const once = toChatMediaSrc(PUBLIC);
    expect(toChatMediaSrc(once)).toBe(once);
  });

  it('passes everything else through unchanged, null-safe', () => {
    expect(toChatMediaSrc('/api/whatsapp/media/123')).toBe('/api/whatsapp/media/123');
    expect(toChatMediaSrc('https://example.com/a.png')).toBe('https://example.com/a.png');
    expect(toChatMediaSrc('blob:http://x/1')).toBe('blob:http://x/1');
    expect(toChatMediaSrc(null)).toBeNull();
    expect(toChatMediaSrc(undefined)).toBeUndefined();
    expect(toChatMediaSrc('')).toBe('');
  });

  it('does not rewrite a chat-media URL with an unsafe path', () => {
    const u = 'https://abc.supabase.co/storage/v1/object/public/chat-media/account-x/../y.jpg';
    expect(toChatMediaSrc(u)).toBe(u);
  });
});

describe('isChatMediaUrl', () => {
  it('is true only for parseable chat-media URLs', () => {
    expect(isChatMediaUrl(PUBLIC)).toBe(true);
    expect(isChatMediaUrl('https://example.com/a.png')).toBe(false);
    expect(isChatMediaUrl(null)).toBe(false);
  });
});
