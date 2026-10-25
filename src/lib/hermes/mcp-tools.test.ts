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
  it('expone las seis herramientas de solo lectura', async () => {
    const client = await connect(vi.fn());

    const { tools } = await client.listTools();

    expect(tools.map((t) => t.name).sort()).toEqual([
      'alertas',
      'buscar_conversacion',
      'leer_mensajes',
      'listar_operaciones',
      'resumen_periodo',
      'tasas_vigentes',
      'ver_calculadora',
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

  it('un error de la base se devuelve como error de herramienta', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: { message: 'boom' } });
    const client = await connect(rpc);

    const res = await client.callTool({ name: 'tasas_vigentes', arguments: {} });

    expect(res.isError).toBe(true);
    const first = res.content as Array<{ type: string; text?: string }>;
    expect(first[0]?.text).toContain('boom');
  });
});
