import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

import { buildVistazo } from './vistazo';

function db(byName: Record<string, { data?: unknown; error?: unknown }>): SupabaseClient {
  const from = vi.fn(() => ({
    select: () => ({
      eq: () => Promise.resolve(byName.incidentes ?? { data: null, error: null }),
    }),
  }));
  return {
    rpc: vi.fn((name: string) => Promise.resolve(byName[name] ?? { data: null, error: null })),
    from,
  } as unknown as SupabaseClient;
}

const cuadreHoy = {
  data: {
    crm: { completadas: 17, sin_linea_en_finanzas: [{ operacion: 'ab' }, { operacion: 'cd' }] },
    finanzas: { lineas: 15 },
  },
};

describe('buildVistazo', () => {
  it("reads the four blocks with the panel own functions", async () => {
    const client = db({
      hermes_cuadre_finanzas: cuadreHoy,
      hermes_sin_responder: { data: { conversaciones: 3, mas_antiguo: '2026-10-25T14:11:00Z' } },
      incidentes: {
        data: [{ quoted_source_amount: 26000 }, { quoted_source_amount: 5000 }],
      },
    });

    const vistazo = await buildVistazo(client);

    expect(vistazo.cuadre).toEqual({ completadas: 17, conLinea: 15, sinLinea: 2 });
    expect(vistazo.sinResponder?.conversaciones).toBe(3);
    expect(vistazo.incidencias).toEqual({ operaciones: 2, importeGyd: 31000 });
    // Sin responder asks for the same seven-day window as the inbox.
    const llamada = (client.rpc as unknown as { mock: { calls: Array<[string, unknown]> } }).mock.calls
      .find(([name]) => name === 'hermes_sin_responder');
    expect(llamada?.[1]).toMatchObject({ p_desde: expect.any(String) });
    // The semana call reuses the same function over seven days.
    expect((client.rpc as unknown as { mock: { calls: Array<[string, unknown]> } }).mock.calls
      .filter(([name]) => name === 'hermes_cuadre_finanzas')).toHaveLength(2);
  });

  it('drops a block instead of inventing a number when its call fails', async () => {
    const client = db({
      hermes_cuadre_finanzas: { error: { message: 'boom' } },
      hermes_sin_responder: { error: { message: 'missing function' } },
      incidentes: { error: { message: 'boom' } },
    });

    const vistazo = await buildVistazo(client);

    expect(vistazo.cuadre).toBeNull();
    expect(vistazo.sinResponder).toBeNull();
    expect(vistazo.incidencias).toBeNull();
    expect(vistazo.semana).toBeNull();
  });
});
