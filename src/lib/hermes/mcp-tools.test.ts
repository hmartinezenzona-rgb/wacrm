import { describe, it, expect, vi } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { SupabaseClient } from '@supabase/supabase-js';

import { buildHermesServer } from './mcp-tools';

async function connect(rpc: ReturnType<typeof vi.fn>) {
  const db = { rpc } as unknown as SupabaseClient;
  const server = buildHermesServer(db);
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);
  const client = new Client({ name: 'test', version: '1.0.0' });
  await client.connect(clientTransport);
  return client;
}

describe('Hermes MCP tools', () => {
  it('expone las nueve herramientas de solo lectura', async () => {
    const client = await connect(vi.fn());

    const { tools } = await client.listTools();

    expect(tools.map((t) => t.name).sort()).toEqual([
      'alertas',
      'buscar_conversacion',
      'cuadre_finanzas',
      'leer_mensajes',
      'listar_operaciones',
      'resumen_periodo',
      'tasas_vigentes',
      'ver_calculadora',
      'verificar_trans_id',
    ]);
  });

  it('buscar_conversacion llama a la RPC y devuelve su JSON', async () => {
    const rpc = vi.fn().mockResolvedValue({
      data: [{ conversacion: 'ab12cd34', telefono: '599...' }],
      error: null,
    });
    const client = await connect(rpc);

    const res = await client.callTool({
      name: 'buscar_conversacion',
      arguments: { consulta: '599' },
    });

    expect(rpc).toHaveBeenCalledWith('hermes_buscar_conversacion', { p_consulta: '599' });
    const first = res.content as Array<{ type: string; text?: string }>;
    expect(first[0]?.text).toContain('ab12cd34');
  });

  it('cuadre_finanzas pasa el rango a la RPC', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: { desde: '2026-10-24' }, error: null });
    const client = await connect(rpc);

    await client.callTool({
      name: 'cuadre_finanzas',
      arguments: { desde: '2026-10-20', hasta: '2026-10-24' },
    });

    expect(rpc).toHaveBeenCalledWith('hermes_cuadre_finanzas', {
      p_desde: '2026-10-20',
      p_hasta: '2026-10-24',
    });
  });

  it('un error de la base se devuelve como error de herramienta', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: { message: 'boom' } });
    const client = await connect(rpc);

    const res = await client.callTool({ name: 'tasas_vigentes', arguments: {} });

    expect(res.isError).toBe(true);
    const first = res.content as Array<{ type: string; text?: string }>;
    expect(first[0]?.text).toContain('boom');
  });

describe('verificar_trans_id', () => {
  it('consulta el libro con el token y devuelve el veredicto', async () => {
    process.env.HERMES_VERIFICADOR_URL = 'https://n8n.example/webhook/verificar-comprobante-prod';
    process.env.HERMES_VERIFICADOR_TOKEN = 'secreto';
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify([
          {
            existe: true, referencia: '10404131818653', monto: '15000.00',
            moneda: 'GYD', fecha: '25/10/2026', titular: 'Osmany',
          },
        ]),
        { status: 200 },
      ),
    );
    vi.stubGlobal('fetch', fetchMock);
    const client = await connect(vi.fn());

    const res = await client.callTool({
      name: 'verificar_trans_id',
      arguments: { trans_id: '10404131818653' },
    });

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://n8n.example/webhook/verificar-referencia-prod');
    expect(JSON.parse(String(init.body))).toEqual({ token: 'secreto', referencia: '10404131818653' });
    const text = (res.content as Array<{ text: string }>)[0].text;
    expect(text).toContain('Comprobante: en el libro de MMG');
    expect(text).toContain('Monto: 15,000 GYD');
    expect(text).toContain('Titular: Osmany');

    vi.unstubAllGlobals();
    delete process.env.HERMES_VERIFICADOR_URL;
    delete process.env.HERMES_VERIFICADOR_TOKEN;
  });
});
});
