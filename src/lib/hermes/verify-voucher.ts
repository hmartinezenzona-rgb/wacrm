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
 * The verdict as the lines Hermes should read. Facts only: the model must not
 * be nudged beyond what the verifier measured.
 */
export function voucherSummary(v: VoucherVerdict): string {
  const si = (value: boolean) => (value ? 'sí' : 'no');
  const lines = [
    'Verificador de comprobantes (resultado automático y de solo lectura):',
    `- ¿Está en el libro de depósitos de MMG?: ${si(v.en_libro)}`,
    `- ¿Es un comprobante?: ${si(v.es_comprobante)}${v.tipo && v.tipo !== 'comprobante' ? ` (lo clasificó como "${v.tipo}")` : ''}`,
    `- Monto leído: ${v.monto === null ? 'no legible' : `${v.monto} ${v.moneda ?? ''}`.trim()}`,
    `- Referencia: ${v.referencia ?? 'no legible'}`,
    `- Banco emisor: ${v.banco_emisor ?? 'no legible'}`,
    `- Fecha: ${v.fecha ?? 'no legible'}`,
    `- Giros leídos: ${v.leida_girada ? 'sí, la primera lectura no cuadró' : 'solo la original'}`,
  ];
  if (v.alertas.length) {
    lines.push(`- Alertas: ${v.alertas.join(' | ')}`);
  }
  lines.push(
    'Usa estos datos tal cual y no añadas cifras que no estén aquí. Si el monto no es legible o hay alertas, dilo antes de dar nada por bueno.',
  );
  return lines.join('\n');
}
