import { NextResponse } from 'next/server'
import { supabaseAdmin } from '@/lib/automations/admin-client'
import { avisar, fechaCorta } from '@/lib/avisos/push'

// Lo llama la base de datos (trigger 302) cuando se crea un encargo.
// No confía en lo que recibe: con el id relee el encargo y solo avisa si es
// de los últimos 15 minutos y todavía no se avisó (el UPDATE lo marca de
// forma atómica, así que un aviso nunca sale dos veces).
export async function POST(request: Request) {
  const body = await request.json().catch(() => null)
  const dealId = typeof body?.deal_id === 'string' ? body.deal_id : ''
  if (body?.tipo !== 'nuevo' || !/^[0-9a-f-]{36}$/.test(dealId)) {
    return NextResponse.json({ error: 'Petición inválida' }, { status: 400 })
  }
  const db = supabaseAdmin()
  const hace15 = new Date(Date.now() - 15 * 60 * 1000).toISOString()
  const { data: deal } = await db
    .from('deals')
    .update({ avisado_en: new Date().toISOString() })
    .eq('id', dealId)
    .is('avisado_en', null)
    .gte('created_at', hace15)
    .select('id, account_id, title, value, expected_close_date, contact:contacts(name)')
    .maybeSingle()
  if (!deal) return NextResponse.json({ ok: true, avisado: false })

  const nombre = (deal.contact as { name?: string } | null)?.name || 'Un cliente'
  const charolas = (deal.title.match(/^(\d+ charolas?)/) || [])[1] || deal.title
  const cuando = deal.expected_close_date ? ` para el ${fechaCorta(deal.expected_close_date)}` : ''
  const r = await avisar(
    { accountId: deal.account_id },
    {
      title: '🆕 Nuevo encargo',
      body: `${nombre} · ${charolas}${cuando} · $${Number(deal.value).toLocaleString('es-MX')}`,
      url: '/pipelines',
      tag: `encargo-${deal.id}`,
    },
  )
  return NextResponse.json({ ok: true, avisado: true, ...r })
}
