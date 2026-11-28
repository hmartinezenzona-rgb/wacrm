import { beforeEach, describe, expect, it, vi } from 'vitest';

const createSignedUrls = vi.fn();
const from = vi.fn(() => ({ createSignedUrls }));
vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({ storage: { from } }),
}));

import { __resetSignCache } from '@/lib/storage/chat-media-server';

const requireRole = vi.fn();
vi.mock('@/lib/auth/account', async () => {
  const actual = await vi.importActual<typeof import('@/lib/auth/account')>('@/lib/auth/account');
  return {
    ...actual,
    requireRole: (...args: unknown[]) => requireRole(...args),
  };
});

import { POST } from './route';

const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
const PATH = `account-${ACCT}/1.jpg`;
const URL_A = `https://abc.supabase.co/storage/v1/object/public/chat-media/${PATH}`;
const FOREIGN = 'https://abc.supabase.co/storage/v1/object/public/chat-media/account-99999999-1111-4222-8333-444455556666/x.jpg';

function request(body: unknown): Request {
  return new Request('http://local/api/chat-media/sign', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  // The signature cache is module state: without a reset one test would be
  // served by the previous test's cached URLs instead of calling Storage.
  __resetSignCache();
  requireRole.mockResolvedValue({ accountId: ACCT });
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe('POST /api/chat-media/sign', () => {
  it('firma en un solo lote los objetos de la cuenta', async () => {
    createSignedUrls.mockResolvedValue({
      data: [{ path: PATH, signedUrl: 'https://signed/1', error: null }],
      error: null,
    });

    const res = await POST(request({ urls: [URL_A, URL_A] }));

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({
      signed: { [URL_A]: 'https://signed/1' },
      expiresIn: 3600,
    });
    expect(requireRole).toHaveBeenCalledWith('viewer');
    expect(createSignedUrls).toHaveBeenCalledTimes(1);
    expect(createSignedUrls).toHaveBeenCalledWith([PATH], 3600);
  });

  it('nunca firma el objeto de otra cuenta', async () => {
    const res = await POST(request({ urls: [FOREIGN] }));

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ signed: {}, expiresIn: 3600 });
    expect(createSignedUrls).not.toHaveBeenCalled();
  });

  it('rechaza un cuerpo sin urls', async () => {
    const res = await POST(request({ urls: [] }));
    expect(res.status).toBe(400);
  });

  it('un fallo de Storage responde 502', async () => {
    createSignedUrls.mockResolvedValue({ data: null, error: { message: 'boom' } });
    const res = await POST(request({ urls: [URL_A] }));
    expect(res.status).toBe(502);
  });
});
