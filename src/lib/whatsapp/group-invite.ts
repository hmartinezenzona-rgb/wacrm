import type { SupabaseClient } from '@supabase/supabase-js'

import { sendMessageToConversation } from './send-message'
import type { InteractiveCtaUrlPayload } from './interactive'

/** cerebro_config key: 'si' turns the first-message group CTA on. */
export const GRUPO_BOTON_CLAVE = 'grupo_boton'

/** Meta's cta_url body cap; above it the invite falls back to a second message. */
export const INVITACION_CUERPO_MAX = 1024

/** The interactive invitation sent to a new client's first message. */
export function construirInvitacionGrupo(origin: string): InteractiveCtaUrlPayload {
  // The request origin behind nginx can be the internal address, which a
  // phone cannot open; the public site URL wins when it is configured.
  const publica = process.env.NEXT_PUBLIC_SITE_URL?.trim()
  const base = (publica || origin).replace(/\/+$/, '')
  return {
    kind: 'cta_url',
    body: 'Únete a nuestro grupo para estar al día.',
    footer: 'Remesas Ya',
    button_label: 'Unirme al grupo',
    url: `${base}/grupo`,
  }
}

/**
 * One message: the bot's answer as the body plus the group invitation and
 * button. Returns null when the combined body would exceed Meta's limit;
 * the caller then falls back to the previous two-message flow.
 */
export function construirInvitacionGrupoConTexto(
  texto: string,
  origin: string,
): InteractiveCtaUrlPayload | null {
  const limpio = texto.trim()
  if (!limpio) return null
  const base = construirInvitacionGrupo(origin)
  const body = `${limpio}\n\n${base.body}`
  if (body.length > INVITACION_CUERPO_MAX) return null
  return { ...base, body }
}

async function grupoBotonActivo(db: SupabaseClient): Promise<boolean> {
  const { data } = await db
    .from('cerebro_config')
    .select('valor')
    .eq('clave', GRUPO_BOTON_CLAVE)
    .maybeSingle()
  const valor = String((data as { valor?: string } | null)?.valor ?? '')
    .trim()
    .toLowerCase()
  return ['si', 'sí', 'on', 'true', '1', 'yes'].includes(valor)
}

async function contactoEsAdmin(db: SupabaseClient, contactId: string): Promise<boolean> {
  const { data: links } = await db
    .from('contact_tags')
    .select('tag_id')
    .eq('contact_id', contactId)
  const ids = ((links ?? []) as Array<{ tag_id: string }>)
    .map((l) => l.tag_id)
    .filter(Boolean)
  if (!ids.length) return false
  const { data: tags } = await db.from('tags').select('name').in('id', ids)
  return ((tags ?? []) as Array<{ name: string }>).some(
    (t) => String(t.name).trim().toLowerCase() === 'admin',
  )
}

async function invitacionYaEnviada(
  db: SupabaseClient,
  conversationId: string,
): Promise<boolean> {
  const { data } = await db
    .from('messages')
    .select('id, interactive_payload')
    .eq('conversation_id', conversationId)
    .eq('content_type', 'interactive')
    .limit(50)
  return ((data ?? []) as Array<{ interactive_payload: unknown }>).some(
    (m) => (m.interactive_payload as { kind?: string } | null)?.kind === 'cta_url',
  )
}

/** Flag, Admin tag and a previous CTA: the invitation is allowed. */
export async function puedeInvitarGrupo(
  db: SupabaseClient,
  conversationId: string,
  contactId: string,
): Promise<boolean> {
  if (!(await grupoBotonActivo(db))) return false
  if (await contactoEsAdmin(db, contactId)) return false
  if (await invitacionYaEnviada(db, conversationId)) return false
  return true
}

/** True when the bot has not answered this conversation yet. */
export async function esPrimeraRespuestaAgente(
  db: SupabaseClient,
  conversationId: string,
): Promise<boolean> {
  const { data } = await db
    .from('messages')
    .select('id')
    .eq('conversation_id', conversationId)
    .eq('sender_type', 'agent')
    .limit(1)
  return ((data ?? []) as unknown[]).length === 0
}

const dormir = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

/**
 * Wait for the bot's first reply after `desde`. The webhook fires on the
 * inbound message, but the Cerebro reply is generated asynchronously and
 * can take ~35s; sending the CTA first made it preempt the answer.
 */
export async function esperarRespuestaBot(
  db: SupabaseClient,
  conversationId: string,
  desde: string,
  opts: { timeoutMs?: number; intervalMs?: number } = {},
): Promise<boolean> {
  const timeoutMs = opts.timeoutMs ?? 75000
  const intervalMs = opts.intervalMs ?? 2000
  const limite = Date.now() + timeoutMs
  while (Date.now() < limite) {
    const { data } = await db
      .from('messages')
      .select('id')
      .eq('conversation_id', conversationId)
      .eq('sender_type', 'agent')
      .eq('ai_generated', true)
      .gt('created_at', desde)
      .limit(1)
    if (((data ?? []) as unknown[]).length > 0) return true
    await dormir(intervalMs)
  }
  return false
}

/**
 * First-message invitation, ordered after the bot's answer. If the bot
 * stays silent (modelo_skip) or slow, the CTA is sent after the timeout
 * anyway; the guards are re-checked so it is still once per thread.
 */
export async function enviarInvitacionTrasRespuesta(
  db: SupabaseClient,
  accountId: string,
  conversationId: string,
  contactId: string,
  origin: string,
  desde: string,
  opts: { timeoutMs?: number; intervalMs?: number } = {},
): Promise<boolean> {
  if (!(await puedeInvitarGrupo(db, conversationId, contactId))) return false
  await esperarRespuestaBot(db, conversationId, desde, opts)
  return enviarInvitacionGrupo(db, accountId, conversationId, contactId, origin)
}

/**
 * Send the group invitation once, on a new client's first inbound message.
 * The flag, the Admin tag and a previous CTA in the thread are all guards;
 * this never throws past the caller (the webhook catches and logs).
 */
export async function enviarInvitacionGrupo(
  db: SupabaseClient,
  accountId: string,
  conversationId: string,
  contactId: string,
  origin: string,
): Promise<boolean> {
  if (!(await grupoBotonActivo(db))) return false
  if (await contactoEsAdmin(db, contactId)) return false
  if (await invitacionYaEnviada(db, conversationId)) return false
  await sendMessageToConversation(db, accountId, {
    conversationId,
    messageType: 'interactive',
    interactivePayload: construirInvitacionGrupo(origin),
    aiGenerated: true,
  })
  return true
}
