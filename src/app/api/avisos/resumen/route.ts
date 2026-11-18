import { NextResponse } from 'next/server'
import { supabaseAdmin } from '@/lib/automations/admin-client'
import { avisar, hoySaltillo } from '@/lib/avisos/push'

// Seguimiento de propuestas (cron 320, lun–sáb 9 am Saltillo).
// Avisa de las propuestas que llevan 3 días o más en «Propuesta enviada»
// sin que el cliente conteste. Una sola vez por cuenta y por día
// (push_resumenes), aunque el cron o alguien llame la ruta varias veces.
const DIAS_SIN_RESPUESTA = 3

export async function POST() {
  const db = supabaseAdmin()
  const hoy = hoySaltillo(0)
  const limite = new Date(Date.now() - DIAS_SIN_RESPUESTA * 24 * 60 * 60 * 1000).toISOString()
  const { data: cuentas } = await db.from('push_suscripciones').select('account_id')
  const ids = [...new Set((cuentas ?? []).map((c) => c.account_id as string))]
  const resultados: Record<string, unknown> = {}

  for (const accountId of ids) {
    const { data: deals } = await db
      .from('deals')
      .select('title, etapa_desde, stage:pipeline_stages(name)')
      .eq('account_id', accountId)
      .lte('etapa_desde', limite)
    const pendientes = (deals ?? []).filter((d) =>
      /enviada/i.test((d.stage as { name?: string } | null)?.name || ''),
    )
    if (pendientes.length === 0) {
      resultados[accountId] = 'sin pendientes'
      continue
    }
    const { error: ya } = await db.from('push_resumenes').insert({ account_id: accountId, fecha: hoy })
    if (ya) {
      resultados[accountId] = 'ya enviado'
      continue
    }
    const nombres = pendientes
      .slice(0, 4)
      .map((d) => d.title)
      .join(', ')
    const n = pendientes.length
    resultados[accountId] = await avisar(
      { accountId },
      {
        title: `${n} ${n === 1 ? 'propuesta' : 'propuestas'} sin respuesta`,
        body: `${nombres}${n > 4 ? ' y más' : ''}. Llevan ${DIAS_SIN_RESPUESTA} días o más. Buen momento para dar seguimiento.`,
        url: '/pipelines',
        tag: `seguimiento-${hoy}`,
      },
    )
  }
  return NextResponse.json({ ok: true, hoy, resultados })
}
