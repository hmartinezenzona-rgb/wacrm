// Body validation shared by the reseller totals routes (migration 397
// RPCs). Strict: known keys only, finite numbers, trimmed optional reasons.
// No I/O: each parser returns a typed value or a 400-shaped error message.

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

export const REASON_MAX = 500;
export const AMOUNT_LIMIT = 1e12;

export interface ResetInput {
  /** Trimmed reason, or null when absent/blank (the RPC stores null). */
  reason: string | null;
  /** Amount the dialog confirmed; null means "do not check". */
  expectedTotalGyd: number | null;
}

export interface ResetAllInput {
  reason: string | null;
  expectedGrandTotalGyd: number | null;
}

export interface AdjustInput {
  amountGyd: number;
  reason: string | null;
}

export const fail = (error: string): { ok: false; error: string } => ({ ok: false, error });

export function isObject(body: unknown): body is Record<string, unknown> {
  return typeof body === "object" && body !== null && !Array.isArray(body);
}

function unknownKey(body: Record<string, unknown>, allowed: readonly string[]): string | null {
  return Object.keys(body).find((key) => !allowed.includes(key)) ?? null;
}

function parseReason(value: unknown): Parsed<string | null> {
  if (value === undefined || value === null) return { ok: true, value: null };
  if (typeof value !== "string") return fail("reason must be text");
  const trimmed = value.trim();
  if (trimmed.length > REASON_MAX) {
    return fail(`reason must be at most ${REASON_MAX} characters`);
  }
  return { ok: true, value: trimmed === "" ? null : trimmed };
}

function parseExpectedTotal(value: unknown, field: string): Parsed<number | null> {
  if (value === undefined || value === null) return { ok: true, value: null };
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fail(`${field} must be a finite number`);
  }
  return { ok: true, value };
}

/** Body of POST /api/revendedores/{contactId}/reiniciar. */
export function parseResetBody(body: unknown): Parsed<ResetInput> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["reason", "expectedTotalGyd"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  const reason = parseReason(body.reason);
  if (!reason.ok) return reason;
  const expected = parseExpectedTotal(body.expectedTotalGyd, "expectedTotalGyd");
  if (!expected.ok) return expected;

  return { ok: true, value: { reason: reason.value, expectedTotalGyd: expected.value } };
}

/** Body of POST /api/revendedores/reiniciar (reset all). */
export function parseResetAllBody(body: unknown): Parsed<ResetAllInput> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["reason", "expectedGrandTotalGyd"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  const reason = parseReason(body.reason);
  if (!reason.ok) return reason;
  const expected = parseExpectedTotal(body.expectedGrandTotalGyd, "expectedGrandTotalGyd");
  if (!expected.ok) return expected;

  return { ok: true, value: { reason: reason.value, expectedGrandTotalGyd: expected.value } };
}

/** Body of POST /api/revendedores/{contactId}/ajustes: signed, non-zero GYD. */
export function parseAdjustBody(body: unknown): Parsed<AdjustInput> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["amountGyd", "reason"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  const amount = body.amountGyd;
  if (typeof amount !== "number" || !Number.isFinite(amount)) {
    return fail("amountGyd must be a finite number");
  }
  if (amount === 0) return fail("amountGyd must be non-zero");
  if (Math.abs(amount) >= AMOUNT_LIMIT) return fail("amountGyd must be under 1e12");

  const reason = parseReason(body.reason);
  if (!reason.ok) return reason;

  return { ok: true, value: { amountGyd: amount, reason: reason.value } };
}
