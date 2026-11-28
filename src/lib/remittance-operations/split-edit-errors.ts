// ============================================================
// Spanish user messages for the 22023 errors of crm_editar_reparto
// (migration 394). The RPC speaks English; the panel's operators read
// Spanish, so the route translates every known message and keeps the
// original text for anything it does not recognise.
// ============================================================

const EXACT: Record<string, string> = {
  "operation is closed": "La operación está cerrada",
  "the split can only be edited on a remesa operation":
    "El reparto solo se puede editar en una operación de remesa",
  "partes must be a JSON array of shares": "Las partes deben ser una lista",
  "a split needs at least 2 shares": "Un reparto necesita al menos 2 partes",
  "the operation has no destination total: set the total first":
    "La operación no tiene total de destino: corrige el total primero",
  "the operation has no destination currency: set it first":
    "La operación no tiene moneda de destino: defínela primero",
};

const PATTERNS: Array<[RegExp, (m: RegExpMatchArray) => string]> = [
  [
    /^the operation has a (.+) recipient: only card splits can be edited here$/,
    (m) => `La operación tiene un destinatario ${m[1]}: aquí solo se puede editar el reparto por tarjeta`,
  ],
  [
    /^the shares add up to (\S+) but the operation total is (\S+) \(difference (\S+)\)$/,
    (m) => `Las partes suman ${m[1]} pero el total de la operación es ${m[2]} (diferencia ${m[3]})`,
  ],
  [/^share (\d+) must be a JSON object$/, (m) => `Parte ${m[1]}: formato no válido`],
  [/^share (\d+): unknown field: (.+)$/, (m) => `Parte ${m[1]}: campo desconocido «${m[2]}»`],
  [/^share (\d+): id must be a uuid or null$/, (m) => `Parte ${m[1]}: identificador no válido`],
  [/^share (\d+): the same share is listed twice$/, (m) => `Parte ${m[1]}: el mismo destinatario está repetido`],
  [
    /^share (\d+): beneficiary does not belong to this operation or is not current$/,
    (m) => `Parte ${m[1]}: ese destinatario no pertenece a la operación o ya no está vigente`,
  ],
  [
    /^share (\d+): invalid beneficiary_type: .* \(a split takes card rails only\)$/,
    (m) => `Parte ${m[1]}: tipo de destinatario no válido (un reparto solo admite tarjetas)`,
  ],
  [
    /^share (\d+): card_number must be exactly 16 digits$/,
    (m) => `Parte ${m[1]}: la tarjeta debe tener exactamente 16 dígitos`,
  ],
  [
    /^share (\d+): phone must be 8 to 15 digits$/,
    (m) => `Parte ${m[1]}: el teléfono debe tener entre 8 y 15 dígitos`,
  ],
  [
    /^share (\d+): amount is required and must be greater than 0$/,
    (m) => `Parte ${m[1]}: el monto es obligatorio y debe ser mayor que cero`,
  ],
  [
    /^share (\d+): currency (\S+) does not match the operation's destination currency (\S+)$/,
    (m) => `Parte ${m[1]}: la moneda ${m[2]} no coincide con la de la operación (${m[3]})`,
  ],
];

/** The Spanish text for a crm_editar_reparto 22023 message; the original message when it is not a known one. */
export function translateSplitEditError(message: string): string {
  const exact = EXACT[message];
  if (exact) return exact;
  for (const [pattern, build] of PATTERNS) {
    const match = message.match(pattern);
    if (match) return build(match);
  }
  return message;
}
