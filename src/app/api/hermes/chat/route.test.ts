import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  toErrorResponse: vi.fn(),
}));

vi.mock('@/lib/auth/account', () => ({
  requireRole: mocks.requireRole,
  toErrorResponse: mocks.toErrorResponse,
}));

import { POST } from './route';

function request(body: unknown): Request {
  return new Request('http://local/api/hermes/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  mocks.requireRole.mockReset();
  mocks.toErrorResponse.mockReset();
  mocks.requireRole.mockResolvedValue({ accountId: 'a1' });
  delete process.env.HERMES_API_URL;
  delete process.env.HERMES_API_KEY;
});

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.HERMES_API_URL;
  delete process.env.HERMES_API_KEY;
});

describe('POST /api/hermes/chat', () => {
  it('exige sesión de admin', async () => {
    mocks.requireRole.mockRejectedValue(new Error('nope'));
    mocks.toErrorResponse.mockReturnValue(new Response('{}', { status: 403 }));

    const res = await POST(request({ messages: [{ role: 'user', content: 'hola' }] }));

    expect(res.status).toBe(403);
    expect(mocks.requireRole).toHaveBeenCalledWith('admin');
  });

  it('sin configuración responde 503', async () => {
    const res = await POST(request({ messages: [{ role: 'user', content: 'hola' }] }));
    expect(res.status).toBe(503);
  });

  it('reenvía al API server de Hermes y devuelve la respuesta', async () => {
    process.env.HERMES_API_URL = 'http://127.0.0.1:18643';
    process.env.HERMES_API_KEY = 'k';
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ choices: [{ message: { content: 'Hola, soy Hermes' } }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );
    vi.stubGlobal('fetch', fetchMock);

    const res = await POST(request({ messages: [{ role: 'user', content: 'hola' }] }));

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ reply: 'Hola, soy Hermes' });
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('http://127.0.0.1:18643/v1/chat/completions');
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer k');
  });

  it('un fallo de Hermes se traduce a 502', async () => {
    process.env.HERMES_API_URL = 'http://127.0.0.1:18643';
    process.env.HERMES_API_KEY = 'k';
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('boom', { status: 500 })));

    const res = await POST(request({ messages: [{ role: 'user', content: 'hola' }] }));
    expect(res.status).toBe(502);
  });
});
