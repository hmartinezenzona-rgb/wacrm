import { NextResponse } from 'next/server'
import { supabaseAdmin } from '@/lib/automations/admin-client'
import { avisar, hoySaltillo } from '@/lib/avisos/push'
import { normalizar } from '@/lib/negocio/config'
import { negocioDeCuenta } from '@/lib/negocio/servidor'

// Seguimiento (cron 320, lun–sáb 9 am Saltillo). Cada negocio dice en
// negocio_config.avisos.seguimiento qué columna revisar y cuántos días
// («Propuesta enviada», 3 días). Avisa de las tarjetas que llevan ese
// tiempo o más ahí. Una sola vez por cuenta y por día (push_resumenes),
// aunque el cron o alguien llame la ruta varias veces.
export async function POST() {
  const db = supabaseAdmin()
  const hoy = hoySaltillo(0)
  const { data: cuentas } = await db.from('push_suscripciones').select('account_id')
  const ids = [...new Set((cuentas ?? []).map((c) => c.account_id as string))]
  const resultados: Record<string, unknown> = {}

  for (const accountId of ids) {
    const seg = (await negocioDeCuenta(db, accountId)).avisos.seguimiento
    if (!seg) {
      resultados[accountId] = 'sin seguimiento'
      continue
    }
    const limite = new Date(Date.now() - seg.dias * 24 * 60 * 60 * 1000).toISOString()
    const { data: deals } = await db
      .from('deals')
      .select('title, etapa_desde, stage:pipeline_stages(name)')
      .eq('account_id', accountId)
      .eq('status', 'open')
      .lte('etapa_desde', limite)
    const pendientes = (deals ?? []).filter(
      (d) => normalizar((d.stage as { name?: string } | null)?.name || '') === normalizar(seg.columna),
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
        title: `${n} ${n === 1 ? seg.singular : seg.plural} sin respuesta`,
        body: `${nombres}${n > 4 ? ' y más' : ''}. Llevan ${seg.dias} días o más. Buen momento para dar seguimiento.`,
        url: '/pipelines',
        tag: `seguimiento-${hoy}`,
      },
    )
  }
  return NextResponse.json({ ok: true, hoy, resultados })
}
