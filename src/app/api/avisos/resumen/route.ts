import { NextResponse } from 'next/server'
import { supabaseAdmin } from '@/lib/automations/admin-client'
import { avisar, fechaCorta, hoySaltillo } from '@/lib/avisos/push'

// Resumen de la noche (cron 302, 7 pm Saltillo): qué hay que cocinar mañana.
// Se manda una sola vez por cuenta y por día (push_resumenes), aunque el cron
// o alguien llame la ruta varias veces.
export async function POST() {
  const db = supabaseAdmin()
  const manana = hoySaltillo(1)
  const { data: cuentas } = await db.from('push_suscripciones').select('account_id')
  const ids = [...new Set((cuentas ?? []).map((c) => c.account_id as string))]
  const resultados: Record<string, unknown> = {}

  for (const accountId of ids) {
    const { data: deals } = await db
      .from('deals')
      .select('title, notes, stage:pipeline_stages(name)')
      .eq('account_id', accountId)
      .eq('expected_close_date', manana)
    const vivos = (deals ?? []).filter((d) => !/cancel/i.test((d.stage as { name?: string } | null)?.name || ''))
    if (vivos.length === 0) {
      resultados[accountId] = 'sin encargos'
      continue
    }
    const { error: ya } = await db.from('push_resumenes').insert({ account_id: accountId, fecha: manana })
    if (ya) {
      resultados[accountId] = 'ya enviado'
      continue
    }
    let charolas = 0
    const cuenta: Record<string, number> = {}
    for (const d of vivos) {
      for (const linea of (d.notes || '').split('\n')) {
        const m = linea.match(/^\s*charola[^:]*:\s*(.+)$/i)
        if (!m) continue
        charolas++
        for (const x of m[1].split(',').map((s: string) => s.trim()).filter(Boolean)) cuenta[x] = (cuenta[x] || 0) + 1
      }
    }
    const top = Object.entries(cuenta)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5)
      .map(([k, v]) => `${v} ${k.toLowerCase()}`)
      .join(', ')
    resultados[accountId] = await avisar(
      { accountId },
      {
        title: `🍳 Mañana ${fechaCorta(manana).split(' ')[0]}: ${charolas} ${charolas === 1 ? 'charola' : 'charolas'}`,
        body: `${vivos.length} ${vivos.length === 1 ? 'encargo' : 'encargos'}. ${top}. Toca para ver la lista.`,
        url: '/cocinar',
        tag: `resumen-${manana}`,
      },
    )
  }
  return NextResponse.json({ ok: true, manana, resultados })
}
