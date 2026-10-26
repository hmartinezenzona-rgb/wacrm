// ============================================================
// The four figures behind the idea cards.
//
// Read with the same functions the rest of the panel and Hermes use, so a card
// and an answer cannot disagree. Every block fails on its own: a broken count
// drops that block to null and the card falls back to its abstract preview
// instead of showing a wrong number.
// ============================================================

import type { SupabaseClient } from '@supabase/supabase-js';

export interface Vistazo {
  cuadre: { completadas: number; conLinea: number; sinLinea: number } | null;
  sinResponder: { conversaciones: number; masAntiguo: string | null } | null;
  incidencias: { operaciones: number; importeGyd: number } | null;
  semana: { facturadoGyd: number; invertidoGyd: number; retornoGyd: number } | null;
}

const number = (value: unknown): number => {
  const n = typeof value === 'string' ? Number(value) : value;
  return typeof n === 'number' && Number.isFinite(n) ? n : 0;
};

export async function buildVistazo(
  db: SupabaseClient,
  /** RLS-scoped client: the operations table is not readable with the service key. */
  sessionDb: SupabaseClient = db,
): Promise<Vistazo> {
  const rango = lastSevenDays();
  // The inbox itself works on a seven-day window; the card follows it so it
  // does not say "0 waiting" while the mailbox holds unanswered chats.
  const desdeSemana = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const [hoy, semana, sinResponder, tablero] = await Promise.all([
    db.rpc('hermes_cuadre_finanzas', { p_desde: null, p_hasta: null }),
    db.rpc('hermes_cuadre_finanzas', { p_desde: rango.desde, p_hasta: rango.hasta }),
    db.rpc('hermes_sin_responder', { p_desde: desdeSemana }),
    // Service role has no grant on this table, so it is read with the admin's
    // own session; RLS already limits it to what they can see in the board.
    sessionDb.from('remittance_operations').select('quoted_source_amount').eq('status', 'incident'),
  ]);

  for (const [name, result] of [
    ['cuadre hoy', hoy],
    ['semana', semana],
    ['sin responder', sinResponder],
    ['incidencias', tablero],
  ] as const) {
    if (result.error) console.error(`[hermes vistazo] ${name}:`, result.error.message);
  }

  const hoyData = hoy.error ? null : ((hoy.data ?? null) as Record<string, unknown> | null);
  const crm = (hoyData?.crm ?? null) as Record<string, unknown> | null;
  const finanzas = (hoyData?.finanzas ?? null) as Record<string, unknown> | null;

  const semanaData = semana.error ? null : ((semana.data ?? null) as Record<string, unknown> | null);
  const semanaFin = (semanaData?.finanzas ?? null) as Record<string, unknown> | null;

  const sr = sinResponder.error ? null : ((sinResponder.data ?? null) as Record<string, unknown> | null);

  const incidentes = tablero.error ? null : ((tablero.data ?? []) as Array<Record<string, unknown>>);

  return {
    cuadre:
      crm && finanzas
        ? {
            completadas: number(crm.completadas),
            conLinea: number(finanzas.lineas),
            sinLinea: Array.isArray(crm.sin_linea_en_finanzas)
              ? crm.sin_linea_en_finanzas.length
              : 0,
          }
        : null,
    sinResponder: sr
      ? {
          conversaciones: number(sr.conversaciones),
          masAntiguo: typeof sr.mas_antiguo === 'string' ? sr.mas_antiguo : null,
        }
      : null,
    incidencias: incidentes
      ? {
          operaciones: incidentes.length,
          importeGyd: incidentes.reduce(
            (sum, op) => sum + number(op.quoted_source_amount ?? op.quotedSourceAmount),
            0,
          ),
        }
      : null,
    semana: semanaFin
      ? {
          facturadoGyd: number(semanaFin.facturado_gyd),
          invertidoGyd: number(semanaFin.invertido_gyd),
          retornoGyd: number(semanaFin.retorno_gyd),
        }
      : null,
  };
}

/** Seven Guyana days up to and including today, the card's "semana". */
function lastSevenDays(): { desde: string; hasta: string } {
  const now = new Date();
  const guyana = new Date(now.getTime() - 4 * 60 * 60 * 1000);
  const hasta = guyana.toISOString().slice(0, 10);
  const desdeDate = new Date(guyana.getTime() - 6 * 24 * 60 * 60 * 1000);
  return { desde: desdeDate.toISOString().slice(0, 10), hasta };
}

