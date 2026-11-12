import { NextResponse } from 'next/server'
import { getCurrentAccount, toErrorResponse } from '@/lib/auth/account'
import { supabaseAdmin } from '@/lib/automations/admin-client'

// Guarda (o actualiza) la suscripción de avisos de este celular.
export async function POST(request: Request) {
  let ctx
  try {
    ctx = await getCurrentAccount()
  } catch (err) {
    return toErrorResponse(err)
  }
  const body = await request.json().catch(() => null)
  const sub = body?.subscription
  const endpoint = typeof sub?.endpoint === 'string' ? sub.endpoint : ''
  const p256dh = typeof sub?.keys?.p256dh === 'string' ? sub.keys.p256dh : ''
  const auth = typeof sub?.keys?.auth === 'string' ? sub.keys.auth : ''
  if (!endpoint.startsWith('https://') || !p256dh || !auth) {
    return NextResponse.json({ error: 'Suscripción inválida' }, { status: 400 })
  }
  const { error } = await supabaseAdmin()
    .from('push_suscripciones')
    .upsert(
      {
        account_id: ctx.accountId,
        user_id: ctx.userId,
        endpoint,
        p256dh,
        auth,
        dispositivo: typeof body?.dispositivo === 'string' ? body.dispositivo.slice(0, 200) : null,
      },
      { onConflict: 'endpoint' },
    )
  if (error) return NextResponse.json({ error: error.message }, { status: 500 })
  return NextResponse.json({ ok: true })
}
