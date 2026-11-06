// Body validation shared by the CUP inventory routes. Strict: known keys only, finite numbers inside the column bounds.
import { UUID_RE } from "@/lib/remittance-operations/route-helpers";

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

export interface CardInput {
  name?: string;
  /** "" clears the stored last 4 (update only). */
  last4?: string;
  priority?: number;
  dailyLimitCup?: number;
  active?: boolean;
}

export interface LotInput {
  cardId: string;
  amountCup: number;
  rateCupPerUsdt: number;
  note?: string;
  loadedAt?: string;
}

export interface LotPatch {
  amountCup?: number;
  rateCupPerUsdt?: number;
  /** "" clears the note. */
  note?: string;
}

export const fail = (error: string): { ok: false; error: string } => ({ ok: false, error });

export function isObject(body: unknown): body is Record<string, unknown> {
  return typeof body === "object" && body !== null && !Array.isArray(body);
}

export function unknownKey(body: Record<string, unknown>, allowed: readonly string[]): string | null {
  return Object.keys(body).find((key) => !allowed.includes(key)) ?? null;
}

export function isPositive(value: unknown, limit: number): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 && value < limit;
}

export const AMOUNT_LIMIT = 1e12;
const RATE_LIMIT = 1e9;
export const NOTE_MAX = 500;

export function parseCardBody(body: unknown, mode: "create" | "update"): Parsed<CardInput> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["name", "last4", "priority", "dailyLimitCup", "active"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  const value: CardInput = {};

  if (body.name !== undefined) {
    if (typeof body.name !== "string") return fail("name must be text");
    const name = body.name.trim();
    if (name.length < 1 || name.length > 60) return fail("name must be 1 to 60 characters");
    value.name = name;
  } else if (mode === "create") {
    return fail("name is required");
  }

  if (body.last4 !== undefined && body.last4 !== null) {
    if (typeof body.last4 !== "string") return fail("last4 must be text");
    const last4 = body.last4.trim();
    if (last4 === "" && mode === "create") {
      // nothing to store
    } else if (last4 === "" || /^\d{4}$/.test(last4)) {
      value.last4 = last4;
    } else {
      return fail("last4 must be exactly 4 digits");
    }
  } else if (body.last4 === null && mode === "update") {
    value.last4 = "";
  }

  if (body.priority !== undefined) {
    if (typeof body.priority !== "number" || !Number.isInteger(body.priority) || body.priority < 0 || body.priority > 100000) {
      return fail("priority must be a whole number between 0 and 100000");
    }
    value.priority = body.priority;
  }

  if (body.dailyLimitCup !== undefined) {
    if (!isPositive(body.dailyLimitCup, AMOUNT_LIMIT)) return fail("dailyLimitCup must be a number greater than zero");
    value.dailyLimitCup = body.dailyLimitCup;
  }

  if (body.active !== undefined) {
    if (typeof body.active !== "boolean") return fail("active must be true or false");
    value.active = body.active;
  }

  if (mode === "update" && Object.keys(value).length === 0) return fail("Nothing to update");
  return { ok: true, value };
}

export function parseNote(note: unknown): Parsed<string> {
  if (note === null) return { ok: true, value: "" };
  if (typeof note !== "string") return fail("note must be text");
  const trimmed = note.trim();
  if (trimmed.length > NOTE_MAX) return fail(`note must be at most ${NOTE_MAX} characters`);
  return { ok: true, value: trimmed };
}

export function parseLotBody(body: unknown): Parsed<LotInput> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["cardId", "amountCup", "rateCupPerUsdt", "note", "loadedAt"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  if (typeof body.cardId !== "string" || !UUID_RE.test(body.cardId)) return fail("cardId must be a UUID");
  if (!isPositive(body.amountCup, AMOUNT_LIMIT)) return fail("amountCup must be a number greater than zero");
  if (!isPositive(body.rateCupPerUsdt, RATE_LIMIT)) return fail("rateCupPerUsdt must be a number greater than zero");

  const value: LotInput = { cardId: body.cardId, amountCup: body.amountCup, rateCupPerUsdt: body.rateCupPerUsdt };

  if (body.note !== undefined && body.note !== null) {
    const note = parseNote(body.note);
    if (!note.ok) return note;
    if (note.value !== "") value.note = note.value;
  }

  if (body.loadedAt !== undefined && body.loadedAt !== null) {
    const time = typeof body.loadedAt === "string" ? Date.parse(body.loadedAt) : Number.NaN;
    if (Number.isNaN(time)) return fail("loadedAt must be a date");
    value.loadedAt = new Date(time).toISOString();
  }

  return { ok: true, value };
}

export function parseLotPatchBody(body: unknown): Parsed<LotPatch> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["amountCup", "rateCupPerUsdt", "note"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  const value: LotPatch = {};
  if (body.amountCup !== undefined) {
    if (!isPositive(body.amountCup, AMOUNT_LIMIT)) return fail("amountCup must be a number greater than zero");
    value.amountCup = body.amountCup;
  }
  if (body.rateCupPerUsdt !== undefined) {
    if (!isPositive(body.rateCupPerUsdt, RATE_LIMIT)) return fail("rateCupPerUsdt must be a number greater than zero");
    value.rateCupPerUsdt = body.rateCupPerUsdt;
  }
  if (body.note !== undefined) {
    const note = parseNote(body.note);
    if (!note.ok) return note;
    value.note = note.value;
  }
  if (Object.keys(value).length === 0) return fail("Nothing to update");
  return { ok: true, value };
}

export interface BalanceInput {
  balanceCup: number;
  reason?: string;
}

/** Body of POST .../cards/{cardId}/balance: the real balance of the card (zero allowed) and an optional reason. */
export function parseBalanceBody(body: unknown): Parsed<BalanceInput> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["balanceCup", "reason"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  const balance = body.balanceCup;
  if (typeof balance !== "number" || !Number.isFinite(balance) || balance < 0 || balance >= AMOUNT_LIMIT) {
    return fail("balanceCup must be a number of zero or more");
  }
  const value: BalanceInput = { balanceCup: balance };

  if (body.reason !== undefined && body.reason !== null) {
    if (typeof body.reason !== "string") return fail("reason must be text");
    const reason = body.reason.trim();
    if (reason.length > NOTE_MAX) return fail(`reason must be at most ${NOTE_MAX} characters`);
    if (reason !== "") value.reason = reason;
  }
  return { ok: true, value };
}
