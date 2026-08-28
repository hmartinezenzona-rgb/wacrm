// ============================================================
// POST /api/remesas/deliver  — complete a remittance in Remesas Core.
// GET  /api/remesas/deliver?deal_id=…  — what the Core says right now.
//
// This is the seam between the board and the money. It exists because
// of one rule: the browser must never hold the credential that can
// complete a remittance.
//
//   browser  →  this route (validates the operator's session + role)
//            →  the delivery service, on the Core's own machine
//            →  Remesas Core `transfer_completed`
//
// The delivery service listens on 127.0.0.1 of THIS host, published
// there by a reverse SSH tunnel from the Core's machine. Nothing new
// is exposed to the internet on either side, and Remesas Core keeps
// listening only on its own loopback.
//
// What this route deliberately does NOT do:
//
//   · It does not write `deals.stage_id`. Moving the card is the
//     projector's job, and it moves it because the Core says the
//     remittance is completed — not the other way round. In
//     production the stage change IS the trigger (`deals_stage_notify`
//     → n8n → template), which means dragging a card sends the
//     customer a "your remittance is complete" message whether or not
//     any money moved. That semantics is not ported.
//
//   · It does not take an `operation_id`. The caller passes the deal;
//     the operation is resolved from the projector's map on the other
//     side. An id typed by a human — or copied out of whatever a model
//     said — is the easiest way to pay someone else's remittance.
// ============================================================

import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canSendMessages, isAccountRole } from '@/lib/auth/roles'

const SERVICIO =
  process.env.REMESAS_DELIVERY_URL || 'http://127.0.0.1:8792'
const SECRETO = process.env.REMESAS_DELIVERY_SECRET || ''

/** Session + role, server-side. The hidden button is not the boundary. */
async function operadorAutorizado() {
  const supabase = await createClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()
  if (error || !user) {
    return { ok: false as const, res: NextResponse.json({ error: 'Unauthorized' }, { status: 401 }) }
  }
  const { data: profile } = await supabase
    .from('profiles')
    .select('account_id, account_role')
    .eq('user_id', user.id)
    .maybeSingle()
  const role = profile?.account_role
  // Completing a remittance is at least agent-class, same bar as
  // sending a message. Fails closed on a missing or unknown role.
  if (!profile?.account_id || !isAccountRole(role) || !canSendMessages(role)) {
    return {
      ok: false as const,
      res: NextResponse.json(
        { error: 'Tu rol no permite completar remesas.' },
        { status: 403 },
      ),
    }
  }
  return { ok: true as const, email: user.email ?? user.id }
}

function sinSecreto() {
  return NextResponse.json(
    { error: 'La entrega contra el Core no esta configurada en este entorno.' },
    { status: 503 },
  )
}

export async function GET(request: Request) {
  const auth = await operadorAutorizado()
  if (!auth.ok) return auth.res
  if (!SECRETO) return sinSecreto()

  const dealId = new URL(request.url).searchParams.get('deal_id')
  if (!dealId) {
    return NextResponse.json({ error: 'falta deal_id' }, { status: 400 })
  }
  try {
    const r = await fetch(
      `${SERVICIO}/v1/deliveries/state?deal_id=${encodeURIComponent(dealId)}`,
      { headers: { 'X-Delivery-Secret': SECRETO }, cache: 'no-store' },
    )
    const body = await r.json().catch(() => ({}))
    return NextResponse.json(body, { status: r.ok ? 200 : r.status })
  } catch (err) {
    // Unreachable service is "don't know", never "go ahead".
    return NextResponse.json(
      { error: `no se pudo consultar el Core: ${(err as Error).message}` },
      { status: 502 },
    )
  }
}

export async function POST(request: Request) {
  const auth = await operadorAutorizado()
  if (!auth.ok) return auth.res
  if (!SECRETO) return sinSecreto()

  const body = await request.json().catch(() => ({}))
  const dealId = typeof body?.deal_id === 'string' ? body.deal_id.trim() : ''
  const referencia =
    typeof body?.transfer_reference === 'string'
      ? body.transfer_reference.trim()
      : ''

  if (!dealId) {
    return NextResponse.json({ error: 'falta deal_id' }, { status: 400 })
  }
  // The reference is required here and not only in the Core. The Core
  // leaves it optional because remittances delivered before the column
  // existed genuinely have none; a NEW delivery has no such excuse.
  if (!referencia) {
    return NextResponse.json(
      { error: 'falta la referencia de la transferencia' },
      { status: 400 },
    )
  }

  try {
    const r = await fetch(`${SERVICIO}/v1/deliveries`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Delivery-Secret': SECRETO,
      },
      body: JSON.stringify({
        deal_id: dealId,
        transfer_reference: referencia,
        operator: auth.email,
        // Carried for the service's log only. `transfer_reference` and
        // `wamid` are different things and the Core stores the first.
        proof_wamid:
          typeof body?.proof_wamid === 'string' ? body.proof_wamid : undefined,
      }),
    })
    const datos = await r.json().catch(() => ({}))
    if (!r.ok) {
      return NextResponse.json(
        { error: datos?.detail || datos?.error || `HTTP ${r.status}` },
        { status: r.status },
      )
    }
    return NextResponse.json(datos)
  } catch (err) {
    return NextResponse.json(
      { error: `no se pudo completar en el Core: ${(err as Error).message}` },
      { status: 502 },
    )
  }
}
