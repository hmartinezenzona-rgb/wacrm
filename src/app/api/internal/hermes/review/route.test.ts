import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

const mocks = vi.hoisted(() => ({
  config: vi.fn(),
}));

vi.mock('@supabase/supabase-js', () => ({
  createClient: () => ({
    from: () => {
      const b: Record<string, unknown> = {};
      b.select = () => b;
      b.eq = () => b;
      b.maybeSingle = mocks.config;
      return b;
    },
  }),
}));

import { POST } from './route';

function request(body: unknown, secret?: string): Request {
  return new Request('http://local/api/internal/hermes/review', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(secret === undefined ? {} : { 'x-cerebro-secret': secret }),
    },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  mocks.config.mockReset();
  mocks.config.mockResolvedValue({ data: { valor: 'secreto' }, error: null });
  process.env.HERMES_API_URL = 'http://127.0.0.1:18643';
  process.env.HERMES_API_KEY = 'k';
});

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.HERMES_API_URL;
  delete process.env.HERMES_API_KEY;
  delete process.env.HERMES_API_MODEL;
});

describe('POST /api/internal/hermes/review', () => {
  it('rechaza un secreto ausente o incorrecto', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    expect((await POST(request({ prompt: 'hola' }))).status).toBe(401);
    expect((await POST(request({ prompt: 'hola' }, 'otro'))).status).toBe(401);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('exige prompt', async () => {
    const res = await POST(request({}, 'secreto'));
    expect(res.status).toBe(400);
  });

  it('rechaza un prompt gigante', async () => {
    const res = await POST(request({ prompt: 'x'.repeat(300_001) }, 'secreto'));
    expect(res.status).toBe(413);
  });

  it('sin configuración de Hermes responde 503', async () => {
    delete process.env.HERMES_API_URL;
    const res = await POST(request({ prompt: 'hola' }, 'secreto'));
    expect(res.status).toBe(503);
  });

  it('reenvía al Hermes del CRM y devuelve el contenido', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ choices: [{ message: { content: '{"resumen":"ok"}' } }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );
    vi.stubGlobal('fetch', fetchMock);

    const res = await POST(request({ prompt: 'revisa' }, 'secreto'));

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ content: '{"resumen":"ok"}' });
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('http://127.0.0.1:18643/v1/chat/completions');
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer k');
    expect(JSON.parse(init.body as string).messages[0].content).toBe('revisa');
  });

  it('propaga un fallo del upstream como 502', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('boom', { status: 500 })));
    const res = await POST(request({ prompt: 'revisa' }, 'secreto'));
    expect(res.status).toBe(502);
  });
});
