import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * La conversacion de (account, contact), o null si no hay ninguna.
 *
 * Deliberadamente `.order('created_at').limit(1)` y NO `.single()`.
 *
 * `.single()` devuelve error cuando hay MAS de una fila (PGRST116), y
 * los dos llamadores — el webhook de entrada y la ruta de salida de la
 * API publica — leian ese error como "no existe" y creaban otra. Con
 * eso, en cuanto existian dos conversaciones para un contacto, cada
 * mensaje creaba una mas: un fallo que se alimenta a si mismo.
 *
 * El 24-ago-2026 un cliente nuevo escribio tres mensajes en tres
 * segundos. Dos webhooks concurrentes crearon dos conversaciones (con
 * 60 ms de diferencia), y a partir de ahi salio un chat por mensaje:
 * 29 en una tarde. Como el Cerebro usa el `conversation_id` como
 * `session_id` de su memoria, el bot arranco de cero casi cada vez y
 * el cliente tuvo que repetir cuatro veces el nombre del beneficiario.
 *
 * Si alguna vez vuelve a haber duplicados, la fila mas antigua es la
 * conversacion de verdad: es la que tiene el historial.
 */
export async function findConversationForContact(
  db: SupabaseClient,
  accountId: string,
  contactId: string,
) {
  const { data } = await db
    .from('conversations')
    .select('*')
    .eq('account_id', accountId)
    .eq('contact_id', contactId)
    .order('created_at', { ascending: true })
    .limit(1)
    .maybeSingle();

  return data ?? null;
}
