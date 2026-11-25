// ============================================================
// Panel client for the reseller totals API (slice 5 routes).
//
// Every call uses the caller's session through the app routes; no service
// role here. The routes already mapped the 397 RPC jsonb into the camelCase
// wire model, so the client only unwraps the envelope and types the result.
// A 409 carries the current total the admin must review again (single reset:
// currentTotalGyd; reset all: currentGrandTotalGyd).
// ============================================================

import type {
  ResellerAdjustmentResult,
  ResellerBatchResult,
  ResellerDetail,
  ResellerResetResult,
  ResellerSummaryRead,
} from "./read-model";

export class ResellerRequestError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "ResellerRequestError";
  }
}

export class ResellerConflictError extends ResellerRequestError {
  constructor(
    message: string,
    readonly currentAmountGyd: number | null,
  ) {
    super(message, 409);
    this.name = "ResellerConflictError";
  }
}

interface ErrorBody {
  error?: unknown;
  currentTotalGyd?: unknown;
  currentGrandTotalGyd?: unknown;
}

function finiteAmount(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

async function readJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

async function throwResponseError(
  response: Response,
  conflictKey: "currentTotalGyd" | "currentGrandTotalGyd",
): Promise<never> {
  const body = await readJson(response);
  const record =
    typeof body === "object" && body !== null ? (body as ErrorBody) : {};
  const message =
    typeof record.error === "string"
      ? record.error
      : `Request failed (${response.status})`;
  if (response.status === 409) {
    throw new ResellerConflictError(message, finiteAmount(record[conflictKey]));
  }
  throw new ResellerRequestError(message, response.status);
}

/** The routes wrap their payload: `{ reseller }`, `{ reset }`, `{ batch }`, `{ adjustment }`. */
function unwrap<T>(body: unknown, key: string): T {
  return (body as Record<string, unknown>)[key] as T;
}

function postInit(body: unknown): RequestInit {
  return {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    cache: "no-store",
  };
}

export async function fetchResellerSummary(): Promise<ResellerSummaryRead> {
  const response = await fetch("/api/revendedores", { cache: "no-store" });
  if (!response.ok) await throwResponseError(response, "currentGrandTotalGyd");
  return (await readJson(response)) as ResellerSummaryRead;
}

export async function fetchResellerDetail(contactId: string): Promise<ResellerDetail> {
  const response = await fetch(`/api/revendedores/${contactId}`, { cache: "no-store" });
  if (!response.ok) await throwResponseError(response, "currentTotalGyd");
  return unwrap<ResellerDetail>(await readJson(response), "reseller");
}

export interface ResetOneBody {
  reason: string | null;
  expectedTotalGyd: number | null;
}

export async function resetReseller(
  contactId: string,
  body: ResetOneBody,
): Promise<ResellerResetResult> {
  const response = await fetch(`/api/revendedores/${contactId}/reiniciar`, postInit(body));
  if (!response.ok) await throwResponseError(response, "currentTotalGyd");
  return unwrap<ResellerResetResult>(await readJson(response), "reset");
}

export interface ResetAllBody {
  reason: string | null;
  expectedGrandTotalGyd: number | null;
}

export async function resetAllResellers(body: ResetAllBody): Promise<ResellerBatchResult> {
  const response = await fetch("/api/revendedores/reiniciar", postInit(body));
  if (!response.ok) await throwResponseError(response, "currentGrandTotalGyd");
  return unwrap<ResellerBatchResult>(await readJson(response), "batch");
}

export interface AdjustBody {
  amountGyd: number;
  reason: string | null;
}

export async function adjustReseller(
  contactId: string,
  body: AdjustBody,
): Promise<ResellerAdjustmentResult> {
  const response = await fetch(`/api/revendedores/${contactId}/ajustes`, postInit(body));
  if (!response.ok) await throwResponseError(response, "currentTotalGyd");
  return unwrap<ResellerAdjustmentResult>(await readJson(response), "adjustment");
}
