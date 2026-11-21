import { NextResponse } from 'next/server'
import { supabaseAdmin } from '@/lib/automations/admin-client'
import { avisar } from '@/lib/avisos/push'
import { resumenDeNotas } from '@/lib/negocio/config'
import { negocioDeCuenta } from '@/lib/negocio/servidor'

// Lo llama la base de datos (trigger 302/311) cuando llega una tarjeta nueva.
// No confía en lo que recibe: con el id relee el encargo y solo avisa si es
// de los últimos 15 minutos y todavía no se avisó (el UPDATE lo marca de
// forma atómica, así que un aviso nunca sale dos veces).
export async function POST(request: Request) {
  const body = await request.json().catch(() => null)
  if (body?.tipo === 'humano') return avisarHumano(body)
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
    .select('id, account_id, title, notes, contact:contacts(name)')
    .maybeSingle()
  if (!deal) return NextResponse.json({ ok: true, avisado: false })

  const nombre = (deal.contact as { name?: string } | null)?.name || ''
  // Qué dice el aviso lo decide cada negocio (negocio_config.avisos.nuevo).
  const negocio = await negocioDeCuenta(db, deal.account_id)
  const primero = resumenDeNotas(deal.notes, negocio.avisos.nuevo.resumen)
  const quien = nombre && nombre !== deal.title ? `${deal.title} (${nombre})` : deal.title
  const r = await avisar(
    { accountId: deal.account_id },
    {
      title: negocio.avisos.nuevo.titulo,
      body: primero ? `${quien} · ${primero}` : quien,
      url: '/pipelines',
      tag: `nuevo-${deal.id}`,
    },
  )
  return NextResponse.json({ ok: true, avisado: true, ...r })
}

// Lo llama bot_pasar_a_humano (migración 313) cuando el bot de WhatsApp
// entrega un chat a una persona. Igual que arriba: relee la conversación y
// solo avisa si se pidió en los últimos 15 minutos y no se avisó todavía.
async function avisarHumano(body: { conversation_id?: unknown }) {
  const convId = typeof body.conversation_id === 'string' ? body.conversation_id : ''
  if (!/^[0-9a-f-]{36}$/.test(convId)) {
    return NextResponse.json({ error: 'Petición inválida' }, { status: 400 })
  }
  const db = supabaseAdmin()
  const hace15 = new Date(Date.now() - 15 * 60 * 1000).toISOString()
  const { data: conv } = await db
    .from('conversations')
    .update({ humano_avisado_en: new Date().toISOString() })
    .eq('id', convId)
    .is('humano_avisado_en', null)
    .gte('humano_pedido_en', hace15)
    .select('id, account_id, ai_handoff_summary, contact:contacts(name, phone)')
    .maybeSingle()
  if (!conv) return NextResponse.json({ ok: true, avisado: false })

  const c = conv.contact as { name?: string; phone?: string } | null
  const quien = c?.name || c?.phone || 'Un cliente'
  const motivo = conv.ai_handoff_summary ? ` · ${conv.ai_handoff_summary}` : ''
  const r = await avisar(
    { accountId: conv.account_id },
    {
      title: 'Un cliente quiere hablar contigo',
      body: `${quien}${motivo}`.slice(0, 180),
      url: '/inbox',
      tag: `humano-${conv.id}`,
    },
  )
  return NextResponse.json({ ok: true, avisado: true, ...r })
}
