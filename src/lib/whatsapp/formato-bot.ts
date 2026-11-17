/**
 * Presentación de las respuestas del bot en WhatsApp (AP Suministros).
 *
 * Los modelos de lenguaje escriben en Markdown (**negrita**, ## títulos,
 * [texto](url), "* viñeta") y en párrafos largos. WhatsApp no entiende
 * Markdown: muestra los asteriscos dobles y los gatos tal cual, y un bloque
 * largo en una sola burbuja se lee mal en el celular.
 *
 * Aquí se hacen dos cosas antes de mandar:
 *  1. Pasar Markdown al formato propio de WhatsApp (*negrita*, _cursiva_,
 *     "- " para viñetas, "1. " para numeradas).
 *  2. Dejar los párrafos separados por una línea en blanco, en un solo
 *     mensaje; solo un texto muy largo se parte en 2 o 3 burbujas.
 */
import type { InteractiveButtonsPayload } from './interactive'

export type PiezaBot =
  | { tipo: 'texto'; texto: string }
  | { tipo: 'botones'; payload: InteractiveButtonsPayload }

/** Más de esto en una sola burbuja se parte en párrafos. */
const LARGO_BURBUJA = 700
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

/**
 * Todo va en UNA burbuja, con los párrafos separados por una línea en
 * blanco (también la pregunta final). Julio prefirió esto a mandar la
 * pregunta en un mensaje aparte (16-nov-2026).
 * Solo un texto muy largo se parte, por párrafos y en máximo 3 burbujas;
 * una lista nunca se separa del renglón que la presenta.
 */
export function partirEnBurbujas(texto: string): string[] {
  if (texto.length <= LARGO_BURBUJA) return [texto]
  const parrafos = texto.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean)
  if (parrafos.length < 2) return [texto]

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

  while (burbujas.length > MAX_BURBUJAS) {
    const ultima = burbujas.pop() as string
    burbujas[burbujas.length - 1] += `\n\n${ultima}`
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
