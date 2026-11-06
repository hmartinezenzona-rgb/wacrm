// Body validation shared by the USD inventory routes. Strict: known keys only, finite numbers inside the column bounds.
import { UUID_RE } from "@/lib/remittance-operations/route-helpers";
import { AMOUNT_LIMIT, NOTE_MAX, fail, isObject, isPositive, parseNote, unknownKey, type Parsed } from "@/lib/cup-inventory/payloads";
import type { UsdService } from "./read-model";

export interface UsdCardInput {
  /** Create only: the service of a card never changes. */
  service?: UsdService;
  name?: string;
  /** "" clears the stored last 4 (update only). */
  last4?: string;
  priority?: number;
  monthlyLimitUsd?: number;
  active?: boolean;
}

export interface UsdLotInput {
  cardId: string;
  amountUsd: number;
  usdtPaid: number;
  note?: string;
  loadedAt?: string;
}

export interface UsdLotPatch {
  amountUsd?: number;
  usdtPaid?: number;
  /** "" clears the note. */
  note?: string;
}

export function parseUsdCardBody(body: unknown, mode: "create" | "update"): Parsed<UsdCardInput> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, mode === "create" ? ["service", "name", "last4", "priority", "monthlyLimitUsd", "active"] : ["name", "last4", "priority", "monthlyLimitUsd", "active"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  const value: UsdCardInput = {};

  if (mode === "create") {
    if (body.service !== "CLASICA" && body.service !== "TROPICAL") return fail("service must be CLASICA or TROPICAL");
    value.service = body.service;
  }

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

  if (body.monthlyLimitUsd !== undefined) {
    if (!isPositive(body.monthlyLimitUsd, AMOUNT_LIMIT)) return fail("monthlyLimitUsd must be a number greater than zero");
    value.monthlyLimitUsd = body.monthlyLimitUsd;
  }

  if (body.active !== undefined) {
    if (typeof body.active !== "boolean") return fail("active must be true or false");
    value.active = body.active;
  }

  if (mode === "update" && Object.keys(value).length === 0) return fail("Nothing to update");
  return { ok: true, value };
}

export function parseUsdLotBody(body: unknown): Parsed<UsdLotInput> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["cardId", "amountUsd", "usdtPaid", "note", "loadedAt"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  if (typeof body.cardId !== "string" || !UUID_RE.test(body.cardId)) return fail("cardId must be a UUID");
  if (!isPositive(body.amountUsd, AMOUNT_LIMIT)) return fail("amountUsd must be a number greater than zero");
  if (!isPositive(body.usdtPaid, AMOUNT_LIMIT)) return fail("usdtPaid must be a number greater than zero");

  const value: UsdLotInput = { cardId: body.cardId, amountUsd: body.amountUsd, usdtPaid: body.usdtPaid };

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

export function parseUsdLotPatchBody(body: unknown): Parsed<UsdLotPatch> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["amountUsd", "usdtPaid", "note"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  const value: UsdLotPatch = {};
  if (body.amountUsd !== undefined) {
    if (!isPositive(body.amountUsd, AMOUNT_LIMIT)) return fail("amountUsd must be a number greater than zero");
    value.amountUsd = body.amountUsd;
  }
  if (body.usdtPaid !== undefined) {
    if (!isPositive(body.usdtPaid, AMOUNT_LIMIT)) return fail("usdtPaid must be a number greater than zero");
    value.usdtPaid = body.usdtPaid;
  }
  if (body.note !== undefined) {
    const note = parseNote(body.note);
    if (!note.ok) return note;
    value.note = note.value;
  }
  if (Object.keys(value).length === 0) return fail("Nothing to update");
  return { ok: true, value };
}

export interface UsdBalanceInput {
  balanceUsd: number;
  reason?: string;
}

/** Body of POST .../cards/{cardId}/balance: the real balance of the card (zero allowed) and an optional reason. */
export function parseUsdBalanceBody(body: unknown): Parsed<UsdBalanceInput> {
  if (!isObject(body)) return fail("Body must be a JSON object");
  const extra = unknownKey(body, ["balanceUsd", "reason"]);
  if (extra) return fail(`Unknown field: ${extra}`);

  const balance = body.balanceUsd;
  if (typeof balance !== "number" || !Number.isFinite(balance) || balance < 0 || balance >= AMOUNT_LIMIT) {
    return fail("balanceUsd must be a number of zero or more");
  }
  const value: UsdBalanceInput = { balanceUsd: balance };

  if (body.reason !== undefined && body.reason !== null) {
    if (typeof body.reason !== "string") return fail("reason must be text");
    const reason = body.reason.trim();
    if (reason.length > NOTE_MAX) return fail(`reason must be at most ${NOTE_MAX} characters`);
    if (reason !== "") value.reason = reason;
  }
  return { ok: true, value };
}
