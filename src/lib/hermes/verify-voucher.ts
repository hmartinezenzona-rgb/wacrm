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

/**
 * The verdict as Hermes should read it: one short line, the way the bot
 * answers a customer, and nothing else unless the admin asks.
 */
export function voucherSummary(v: VoucherVerdict): string {
  const referencia = v.referencia && v.referencia !== 'N/A' ? v.referencia : null;
  if (!v.es_comprobante || !referencia) {
    return [
      '[Verificador de comprobantes] No se pudo leer una referencia válida de MMG.',
      'Contesta en UNA sola frase, como el bot al cliente: que la imagen no se ve con claridad y que mande el comprobante ORIGINAL de MMG, no una captura de otro chat.',
      'No añadas nada más: ni cifras, ni análisis del CRM, ni recomendaciones.',
    ].join('\n');
  }

  const monto = v.monto === null ? 'importe no legible' : `${v.monto} ${v.moneda ?? ''}`.trim();
  const datos = [monto, `ref ${referencia}`, v.fecha, v.destinatario].filter(Boolean).join(' · ');
  const lines = [
    `[Verificador de comprobantes] ${v.en_libro ? 'SÍ está en el libro de depósitos de MMG' : 'NO aparece en el libro de depósitos de MMG'}. Datos leídos: ${datos}.`,
    v.en_libro
      ? 'Contesta en UNA sola frase, como el bot al cliente: confirma que el depósito figura en el libro con ese importe.'
      : 'Contesta en UNA sola frase, como el bot al cliente: acusa recibo y di que todavía no figura en el libro. Prohibido decir que está verificado.',
    v.alertas.length ? `Si te sirve para la frase: ${v.alertas[0]}` : '',
    'No añadas análisis del CRM, ni recomendaciones, ni pasos siguientes, salvo que te los pidan.',
  ];
  return lines.filter(Boolean).join('\n');
}
