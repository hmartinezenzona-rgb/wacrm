import { describe, it, expect, vi, beforeEach } from 'vitest';

const mocks = vi.hoisted(() => ({
  config: vi.fn(),
  contact: vi.fn(),
  conversation: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock('@supabase/supabase-js', () => ({
  createClient: () => ({
    from: (table: string) => {
      const terminal =
        table === 'cerebro_config' ? mocks.config
        : table === 'contacts' ? mocks.contact
        : mocks.conversation;
      const b: Record<string, unknown> = {};
      b.select = () => b;
      b.eq = () => b;
      b.order = () => b;
      b.limit = () => b;
      b.maybeSingle = terminal;
      return b;
    },
    rpc: mocks.rpc,
  }),
}));

import { POST } from './route';

function request(body: unknown, secret?: string): Request {
  return new Request('http://local/api/internal/hermes/report', {
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
  mocks.contact.mockReset();
  mocks.conversation.mockReset();
  mocks.rpc.mockReset();
  mocks.config.mockResolvedValue({ data: { valor: 'secreto' }, error: null });
  mocks.contact.mockResolvedValue({ data: { id: 'ct1' }, error: null });
  mocks.conversation.mockResolvedValue({ data: { id: 'conv1' }, error: null });
  mocks.rpc.mockResolvedValue({ data: [{ encolado: true, outbox_id: 'o1' }], error: null });
});

describe('POST /api/internal/hermes/report', () => {
  it('rechaza un secreto ausente o incorrecto', async () => {
    expect((await POST(request({ text: 'hola' }))).status).toBe(401);
    expect((await POST(request({ text: 'hola' }, 'otro'))).status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it('exige texto', async () => {
    expect((await POST(request({ text: '   ' }, 'secreto'))).status).toBe(400);
  });

  it('encola el informe en el outbox del admin', async () => {
    const res = await POST(request({ text: 'Informe del dia' }, 'secreto'));

    expect(res.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith(
      'cerebro_outbox_encolar',
      expect.objectContaining({
        p_telefono: '5219622896918',
        p_texto: 'Informe del dia',
        p_conversation_id: 'conv1',
      }),
    );
    await expect(res.json()).resolves.toMatchObject({ ok: true });
  });
});
