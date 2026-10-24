import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';

/**
 * The read-only MCP surface Hermes gets over the CRM. Every tool is a thin
 * wrapper over a `hermes_*` RPC (migration 314): the model never composes SQL
 * and nothing here writes. The db client is injected so tests can fake it.
 */
export function buildHermesServer(db: SupabaseClient): McpServer {
  const server = new McpServer({ name: 'wacrm-hermes', version: '1.0.0' });

  async function call(rpc: string, args: Record<string, unknown>) {
    const { data, error } = await db.rpc(rpc, args);
    if (error) {
      return {
        content: [{ type: 'text' as const, text: `error: ${error.message}` }],
        isError: true,
      };
    }
    return {
      content: [{ type: 'text' as const, text: JSON.stringify(data) }],
    };
  }

  server.tool(
    'buscar_conversacion',
    'Busca conversaciones del CRM por telefono (digitos), nombre del contacto o los 8 primeros caracteres del id de la conversacion. Devuelve hasta 10 con estado y ultima actividad.',
    { consulta: z.string().describe('telefono, nombre o id8 de la conversacion') },
    ({ consulta }) => call('hermes_buscar_conversacion', { p_consulta: consulta }),
  );

  server.tool(
    'leer_mensajes',
    'Lee los mensajes de una conversacion (por id8 o uuid), del mas reciente al mas antiguo y devueltos en orden cronologico. Los adjuntos se marcan como [tipo].',
    {
      conversacion: z.string().describe('id8 o uuid de la conversacion'),
      limite: z.number().int().min(1).max(200).optional().describe('mensajes a devolver (por defecto 50)'),
      desde: z.string().optional().describe('fecha ISO; solo mensajes desde entonces'),
    },
    ({ conversacion, limite, desde }) =>
      call('hermes_leer_mensajes', {
        p_conv: conversacion,
        p_limite: limite ?? 50,
        p_desde: desde ?? null,
      }),
  );

  server.tool(
    'listar_operaciones',
    'Lista operaciones (remesas) del CRM por conversacion y/o periodo, con servicio, estado e importes.',
    {
      conversacion: z.string().optional().describe('id8 o uuid de la conversacion'),
      desde: z.string().optional().describe('fecha ISO de ultima actualizacion'),
      hasta: z.string().optional().describe('fecha ISO de ultima actualizacion'),
    },
    ({ conversacion, desde, hasta }) =>
      call('hermes_listar_operaciones', {
        p_conv: conversacion ?? null,
        p_desde: desde ?? null,
        p_hasta: hasta ?? null,
      }),
  );

  server.tool(
    'ver_calculadora',
    'Devuelve las lineas de la calculadora de remesas y sus totales (facturado y retorno en GYD) para un periodo.',
    {
      desde: z.string().optional().describe('fecha YYYY-MM-DD'),
      hasta: z.string().optional().describe('fecha YYYY-MM-DD'),
    },
    ({ desde, hasta }) =>
      call('hermes_ver_calculadora', { p_desde: desde ?? null, p_hasta: hasta ?? null }),
  );

  server.tool(
    'alertas',
    'Casos de riesgo del periodo: mensajes que nunca llegaron al bot, promesas sin escritura, chats atascados y salud del outbox.',
    {
      desde: z.string().optional().describe('fecha ISO; por defecto las ultimas 24 h'),
      hasta: z.string().optional().describe('fecha ISO; por defecto ahora'),
    },
    ({ desde, hasta }) => call('hermes_alertas', { p_desde: desde ?? null, p_hasta: hasta ?? null }),
  );

  server.tool(
    'tasas_vigentes',
    'Tasas publicadas del dia, estado de la tasa ARQ USD-MXN y minimos configurados.',
    {},
    () => call('hermes_tasas', {}),
  );

  return server;
}
