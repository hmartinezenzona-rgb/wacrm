// ============================================================
// Avisos push al celular — edición Doña Miriam.
//
// Las llaves VAPID las genera el servidor la primera vez que hacen falta
// y se guardan en `push_llaves` (solo el service role la lee). Así nadie
// tiene que copiarlas ni pegarlas en ningún lado.
// ============================================================

import webpush from 'web-push'
import { supabaseAdmin } from '@/lib/automations/admin-client'

export interface Aviso {
  title: string
  body: string
  /** A dónde lleva al tocar el aviso. */
  url?: string
  /** Avisos con la misma etiqueta se reemplazan en vez de apilarse. */
  tag?: string
}

const SUJETO = 'https://crm-dona-miriam.vercel.app'

let llavesEnMemoria: { publica: string; privada: string } | null = null

export async function obtenerLlaves(): Promise<{ publica: string; privada: string }> {
  if (llavesEnMemoria) return llavesEnMemoria
  const db = supabaseAdmin()
  const { data } = await db.from('push_llaves').select('publica, privada').eq('id', 1).maybeSingle()
  if (data) {
    llavesEnMemoria = data
    return data
  }
  const nuevas = webpush.generateVAPIDKeys()
  // Si dos peticiones llegan a la vez, gana la primera y la otra relee.
  await db
    .from('push_llaves')
    .upsert({ id: 1, publica: nuevas.publicKey, privada: nuevas.privateKey }, { onConflict: 'id', ignoreDuplicates: true })
  const { data: guardadas, error } = await db.from('push_llaves').select('publica, privada').eq('id', 1).single()
  if (error || !guardadas) throw new Error('No se pudieron guardar las llaves de avisos')
  llavesEnMemoria = guardadas
  return guardadas
}

interface Suscripcion {
  id: string
  endpoint: string
  p256dh: string
  auth: string
}

/** Manda el aviso a todos los celulares de la cuenta (o solo a los de un usuario). */
export async function avisar(
  filtro: { accountId: string; userId?: string },
  aviso: Aviso,
): Promise<{ enviados: number; fallidos: number }> {
  const db = supabaseAdmin()
  const llaves = await obtenerLlaves()
  let q = db.from('push_suscripciones').select('id, endpoint, p256dh, auth').eq('account_id', filtro.accountId)
  if (filtro.userId) q = q.eq('user_id', filtro.userId)
  const { data } = await q
  const subs = (data ?? []) as Suscripcion[]

  let enviados = 0
  let fallidos = 0
  await Promise.all(
    subs.map(async (s) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          JSON.stringify(aviso),
          {
            vapidDetails: { subject: SUJETO, publicKey: llaves.publica, privateKey: llaves.privada },
            TTL: 60 * 60 * 6,
            urgency: 'high',
          },
        )
        enviados++
        await db.from('push_suscripciones').update({ ultimo_ok: new Date().toISOString() }).eq('id', s.id)
      } catch (err) {
        fallidos++
        const status = (err as { statusCode?: number }).statusCode
        // 404/410: el celular ya no acepta avisos (se desinstaló o se quitó el permiso).
        if (status === 404 || status === 410) {
          await db.from('push_suscripciones').delete().eq('id', s.id)
        } else {
          console.error('[avisos] fallo al enviar', status, (err as Error).message)
        }
      }
    }),
  )
  return { enviados, fallidos }
}

const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']
const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']

/** "2026-11-13" → "viernes 13 nov" */
export function fechaCorta(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number)
  const x = new Date(Date.UTC(y, m - 1, d, 12))
  return `${DIAS[x.getUTCDay()]} ${d} ${MESES[m - 1]}`
}

/** Fecha de hoy en Saltillo (America/Monterrey), como "YYYY-MM-DD". */
export function hoySaltillo(desplazamientoDias = 0): string {
  const ahora = new Date(Date.now() + desplazamientoDias * 86400000)
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Monterrey' }).format(ahora)
}
