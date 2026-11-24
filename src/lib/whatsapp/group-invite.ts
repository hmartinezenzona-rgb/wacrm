import type { SupabaseClient } from '@supabase/supabase-js'

import { sendMessageToConversation } from './send-message'
import type { InteractiveCtaUrlPayload } from './interactive'

/** cerebro_config key: 'si' turns the first-message group CTA on. */
export const GRUPO_BOTON_CLAVE = 'grupo_boton'

/** The interactive invitation sent to a new client's first message. */
export function construirInvitacionGrupo(origin: string): InteractiveCtaUrlPayload {
  const base = origin.replace(/\/$/, '')
  return {
    kind: 'cta_url',
    body: 'Tenemos un grupo de WhatsApp de Remesas Ya donde compartimos tasas, promociones y avisos al instante.',
    footer: 'Remesas Ya',
    button_label: 'Unirme al grupo',
    url: `${base}/grupo`,
  }
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
