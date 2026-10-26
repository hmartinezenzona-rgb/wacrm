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
    'resumen_periodo',
    'Resumen de un periodo: conversaciones con actividad (id8, contacto, mensajes de cliente y del bot, ultima hora UTC) y totales (mensajes, operaciones creadas/actualizadas/completadas/incidencias). Usalo para "como va el dia" o cualquier conteo por fechas.',
    {
      desde: z.string().optional().describe('fecha ISO de inicio; por defecto hoy 09:00 Guyana'),
      hasta: z.string().optional().describe('fecha ISO de fin; por defecto ahora'),
      limite: z.number().int().min(1).max(500).optional().describe('conversaciones a listar (por defecto 200)'),
    },
    ({ desde, hasta, limite }) =>
      call('hermes_resumen_periodo', {
        p_desde: desde ?? null,
        p_hasta: hasta ?? null,
        p_limite: limite ?? 200,
      }),
  );

  server.tool(
    'cuadre_finanzas',
    'Cuadre de un periodo de dias de negocio (Guyana): operaciones completadas en el CRM, lineas del libro de Finanzas (facturado, invertido, retorno, por servicio) y Control Semanal (lo que sigue en el borrador y lo ya archivado por un corte). Trae calculadas las diferencias: que operaciones completadas no tienen linea en Finanzas y que lineas no corresponden a una operacion completada en el periodo. Usalo para "cuadra el dia" o "cuadra la semana".',
    {
      desde: z.string().optional().describe('fecha YYYY-MM-DD de inicio; por defecto hoy en Guyana'),
      hasta: z.string().optional().describe('fecha YYYY-MM-DD de fin; por defecto el mismo dia'),
    },
    ({ desde, hasta }) =>
      call('hermes_cuadre_finanzas', { p_desde: desde ?? null, p_hasta: hasta ?? null }),
  );

  server.tool(
    'verificar_trans_id',
    'Comprueba si la referencia (TransID) de una transferencia figura en el libro de depósitos de MMG. Es el mismo arbitraje que usa el bot con los comprobantes. Contesta en UNA sola frase, como el bot al cliente: si existe, confírmalo; si no, di que todavía no figura. NO dice si cuadra con una operación del CRM.',
    { trans_id: z.string().describe('referencia numérica de la transferencia') },
    async ({ trans_id }) => {
      const endpoint = process.env.HERMES_VERIFICADOR_URL?.replace(
        'verificar-comprobante',
        'verificar-referencia',
      );
      if (!endpoint) {
        return {
          content: [{ type: 'text' as const, text: 'error: el verificador no está configurado' }],
          isError: true,
        };
      }
      try {
        const res = await fetch(endpoint, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            token: process.env.HERMES_VERIFICADOR_TOKEN ?? '',
            referencia: trans_id,
          }),
          signal: AbortSignal.timeout(30_000),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = (await res.json()) as unknown;
        const item = Array.isArray(data) ? data[0] : data;
        return { content: [{ type: 'text' as const, text: JSON.stringify(item) }] };
      } catch (err) {
        return {
          content: [
            {
              type: 'text' as const,
              text: `error: no se pudo consultar el libro (${err instanceof Error ? err.message : 'desconocido'})`,
            },
          ],
          isError: true,
        };
      }
    },
  );

  server.tool(
    'tasas_vigentes',
    'Tasas publicadas del dia, estado de la tasa ARQ USD-MXN y minimos configurados.',
    {},
    () => call('hermes_tasas', {}),
  );

  return server;
}
