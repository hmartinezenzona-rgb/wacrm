// ============================================================
// Ask the n8n verifier about an image the admin attached.
//
// The Cerebro's own vision block — DeepSeek read, GPT-4o fallback, rotations,
// and the MMG ledger as the arbiter — is exposed as a read-only webhook. This
// module calls it and turns the answer into the few lines Hermes should see.
//
// Fails open on purpose: if the verifier is not configured, is slow or answers
// something unexpected, the chat still works with the pixels alone.
// ============================================================

export interface VoucherVerdict {
  es_comprobante: boolean;
  tipo: string | null;
  monto: number | null;
  moneda: string | null;
  referencia: string | null;
  destinatario: string | null;
  banco_emisor: string | null;
  fecha: string | null;
  en_libro: boolean;
  giro: number;
  leida_girada: boolean;
  alertas: string[];
  hash: string | null;
}

const TIMEOUT_MS = 45_000;

function parseDataUrl(url: string): { base64: string; mime: string } | null {
  const match = /^data:(image\/(?:jpeg|png|webp));base64,(.+)$/.exec(url);
  return match ? { mime: match[1], base64: match[2] } : null;
}

function asVerdict(value: unknown): VoucherVerdict | null {
  if (!value || typeof value !== 'object') return null;
  const v = value as Record<string, unknown>;
  if (typeof v.es_comprobante !== 'boolean' || typeof v.en_libro !== 'boolean') return null;
  return {
    es_comprobante: v.es_comprobante,
    tipo: typeof v.tipo === 'string' ? v.tipo : null,
    monto: typeof v.monto === 'number' ? v.monto : null,
    moneda: typeof v.moneda === 'string' ? v.moneda : null,
    referencia: typeof v.referencia === 'string' ? v.referencia : null,
    destinatario: typeof v.destinatario === 'string' ? v.destinatario : null,
    banco_emisor: typeof v.banco_emisor === 'string' ? v.banco_emisor : null,
    fecha: typeof v.fecha === 'string' ? v.fecha : null,
    en_libro: v.en_libro,
    giro: typeof v.giro === 'number' ? v.giro : 0,
    leida_girada: v.leida_girada === true,
    alertas: Array.isArray(v.alertas) ? v.alertas.filter((a): a is string => typeof a === 'string') : [],
    hash: typeof v.hash === 'string' ? v.hash : null,
  };
}

/** Run the verifier on one image. Never throws. */
export async function verifyVoucher(imageUrl: string): Promise<VoucherVerdict | null> {
  const endpoint = process.env.HERMES_VERIFICADOR_URL;
  const image = parseDataUrl(imageUrl);
  if (!endpoint || !image) return null;
  try {
    const res = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      // The workflow refuses anonymous callers: it spends vision credits and
      // reads the deposits ledger.
      body: JSON.stringify({
        token: process.env.HERMES_VERIFICADOR_TOKEN ?? '',
        imagen_base64: image.base64,
        mime: image.mime,
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!res.ok) return null;
    const data = (await res.json().catch(() => null)) as unknown;
    const item = Array.isArray(data) ? data[0] : data;
    return asVerdict(item);
  } catch {
    return null;
  }
}

/** ISO dates read wrong next to the bot's own wording: 2026-10-25 -> 25/10/2026. */
function readableDate(fecha: string | null): string {
  if (!fecha) return 'no legible';
  const iso = /^(\d{4})-(\d{2})-(\d{2})/.exec(fecha);
  return iso ? `${iso[3]}/${iso[2]}/${iso[1]}` : fecha;
}

/** Guyanese books count in thousands with commas, like the bot does. */
function money(monto: number | null, moneda: string | null): string {
  if (monto === null) return 'no legible';
  return `${monto.toLocaleString('en-US')}${moneda ? ` ${moneda}` : ''}`;
}

/**
 * The verdict as Hermes should answer it: a fixed block, one field per line,
 * the same shape every time. No prose, no CRM analysis.
 */
export function voucherSummary(v: VoucherVerdict): string {
  const referencia = v.referencia && v.referencia !== 'N/A' ? v.referencia : null;
  if (!v.es_comprobante || !referencia) {
    return [
      '[Verificador de comprobantes] La imagen no se pudo leer como comprobante.',
      'Responde EXACTAMENTE con estas dos líneas, sin añadir nada más:',
      'Comprobante: no legible',
      'Detalle: la imagen no se ve con claridad; pide el comprobante ORIGINAL de MMG, no una captura de otro chat.',
    ].join('\n');
  }

  const lines = [
    '[Verificador de comprobantes] Resultado medido por la plataforma. Responde EXACTAMENTE con este bloque, sin texto antes ni después:',
    `Comprobante: ${v.en_libro ? 'en el libro de MMG' : 'no figura en el libro de MMG'}`,
    `Monto: ${money(v.monto, v.moneda)}`,
    `Referencia: ${referencia}`,
    `Fecha: ${readableDate(v.fecha)}`,
    `Destinatario: ${v.destinatario ?? 'no legible'}`,
  ];
  if (v.alertas.length) lines.push(`Nota: ${v.alertas[0]}`);
  lines.push('No añadas análisis del CRM, recomendaciones ni pasos siguientes.');
  return lines.join('\n');
}
