/**
 * Presentación de las respuestas del bot en WhatsApp (AP Suministros).
 *
 * Los modelos de lenguaje escriben en Markdown (**negrita**, ## títulos,
 * [texto](url), "* viñeta") y en párrafos largos. WhatsApp no entiende
 * Markdown: muestra los asteriscos dobles y los gatos tal cual, y un bloque
 * largo en una sola burbuja se lee mal en el celular.
 *
 * Aquí se hacen tres cosas antes de mandar:
 *  1. Pasar Markdown al formato propio de WhatsApp (*negrita*, _cursiva_,
 *     "- " para viñetas, "1. " para numeradas).
 *  2. Partir en 2 o 3 burbujas, siempre en un salto de párrafo.
 *  3. La pregunta final va sola en su propia burbuja.
 */
import type { InteractiveButtonsPayload } from './interactive'

export type PiezaBot =
  | { tipo: 'texto'; texto: string }
  | { tipo: 'botones'; payload: InteractiveButtonsPayload }

/** Más de esto en una sola burbuja se parte en párrafos. */
const LARGO_BURBUJA = 380
const MAX_BURBUJAS = 3

export function aFormatoWhatsapp(entrada: string): string {
  let t = (entrada ?? '').replace(/\r\n?/g, '\n')

  // Bloques de código: WhatsApp los muestra feos; se quedan solo los ``` de monoespacio.
  t = t.replace(/```[a-z]*\n?/gi, '```')

  // Títulos Markdown → renglón en negrita.
  t = t.replace(/^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$/gm, (_m, x: string) => `*${limpiarNegrita(x)}*`)

  // **negrita** / __negrita__ → *negrita*
  t = t.replace(/\*\*(.+?)\*\*/g, (_m, x: string) => `*${x.trim()}*`)
  t = t.replace(/__(.+?)__/g, (_m, x: string) => `*${x.trim()}*`)

  // Viñetas "* " o "• " al inicio del renglón → "- " (las entiende WhatsApp).
  t = t.replace(/^(\s*)[*•·]\s+/gm, '$1- ')

  // Numeradas "1) " → "1. "
  t = t.replace(/^(\s*)(\d{1,2})\)\s+/gm, '$1$2. ')

  // [texto](url) → texto: url
  t = t.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, (_m, txt: string, url: string) =>
    txt.trim() === url ? url : `${txt.trim()}: ${url}`,
  )

  // Separadores "---" y tablas no existen en WhatsApp.
  t = t.replace(/^\s*([-*_])\1{2,}\s*$/gm, '')
  t = t.replace(/^\s*\|?(\s*:?-{3,}:?\s*\|)+\s*:?-*:?\s*$/gm, '')
  t = t.replace(/^\s*\|(.+)\|\s*$/gm, (_m, fila: string) =>
    '- ' + fila.split('|').map((c) => c.trim()).filter(Boolean).join(' · '),
  )

  // Espacios sobrantes y más de una línea en blanco seguida.
  t = t.replace(/[ \t]+$/gm, '')
  t = t.replace(/\n{3,}/g, '\n\n')
  return t.trim()
}

function limpiarNegrita(x: string): string {
  return x.replace(/\*+/g, '').trim()
}

const ES_LISTA = /^(-|\d{1,2}\.)\s/
const TERMINA_EN_PREGUNTA = /\?\s*$/

/**
 * Parte en burbujas solo por párrafos, como escribiría una persona:
 *  - La pregunta final va sola en su propia burbuja (se lee y se contesta).
 *  - Lo demás se agrupa en burbujas de hasta ~380 letras.
 *  - Una lista nunca se separa del renglón que la presenta ("Su solicitud:").
 *  - Nunca más de 3 burbujas.
 */
export function partirEnBurbujas(texto: string): string[] {
  const parrafos = texto.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean)
  if (parrafos.length < 2) return [texto]

  // La pregunta final se aparta, salvo que sea parte de una lista.
  let pregunta: string | null = null
  const ultimo = parrafos[parrafos.length - 1]
  if (TERMINA_EN_PREGUNTA.test(ultimo) && !ES_LISTA.test(ultimo) && ultimo.length <= 300) {
    pregunta = parrafos.pop() as string
  }

  const burbujas: string[] = []
  let actual = ''
  for (const p of parrafos) {
    const junto = actual ? `${actual}\n\n${p}` : p
    const esContinuacion = ES_LISTA.test(p) && /:\s*$/.test(actual)
    if (actual && junto.length > LARGO_BURBUJA && !esContinuacion) {
      burbujas.push(actual)
      actual = p
    } else {
      actual = junto
    }
  }
  if (actual) burbujas.push(actual)
  if (pregunta) burbujas.push(pregunta)

  // Nunca más de 3 burbujas: se juntan las del medio, la pregunta queda sola.
  while (burbujas.length > MAX_BURBUJAS) {
    const fin = pregunta ? 2 : 1
    const i = burbujas.length - fin - 1
    burbujas.splice(i - 1, 2, `${burbujas[i - 1]}\n\n${burbujas[i]}`)
  }
  return burbujas
}


/**
 * Convierte la respuesta del bot en las burbujas de texto a enviar, en orden.
 *
 * Sin botones: Julio los probó (16-nov-2026) y se sienten robóticos en un
 * chat de WhatsApp. Si el modelo todavía escribe una línea
 * "[botones: …]", se quita y queda solo la pregunta.
 */
export function prepararRespuestaBot(entrada: string): PiezaBot[] {
  let texto = aFormatoWhatsapp(entrada)
  texto = texto.replace(/\n?\s*\[botones?\s*:[^\]]*\]\s*$/i, '').trim()
  if (!texto) return []
  return partirEnBurbujas(texto).map((b) => ({ tipo: 'texto', texto: b }))
}
