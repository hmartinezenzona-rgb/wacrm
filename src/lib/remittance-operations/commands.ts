// ============================================================
// Browser-side helpers for the remesa operations panel correction and
// reassignment actions. Thin fetch wrappers over the PATCH/POST API
// routes — no business logic here, just request shaping and a uniform
// result type for the UI to render.
// ============================================================

import type {
  OperationReceiptsRead,
  VerifyDepositItem,
  VerifyDepositResult,
} from "./types";
import type { DeliveryEvidenceRpc } from "./delivery";

export type CommandResult =
  | { ok: true; id?: string }
  | { ok: false; status: number; error: string };

export type FetchResult<T> =
  | { ok: true; data: T }
  | { ok: false; status: number; error: string };

async function getJson(
  url: string,
): Promise<FetchResult<unknown>> {
  let response: Response;
  try {
    response = await fetch(url);
  } catch {
    return { ok: false, status: 0, error: "Network error" };
  }

  if (!response.ok) {
    let message = "Request failed";
    try {
      const errorBody = await response.json();
      message = errorBody?.error ?? message;
    } catch {
      // Response body wasn't JSON; keep the default message.
    }
    return { ok: false, status: response.status, error: message };
  }

  const data = await response.json();
  return { ok: true, data };
}

async function postJsonResult<T>(
  url: string,
  method: "PATCH" | "POST",
  body: unknown,
): Promise<FetchResult<T>> {
  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    return { ok: false, status: 0, error: "Network error" };
  }

  if (!response.ok) {
    let message = "Request failed";
    try {
      const errorBody = await response.json();
      message = errorBody?.error ?? message;
    } catch {
      // Response body wasn't JSON; keep the default message.
    }
    return { ok: false, status: response.status, error: message };
  }

  const data = await response.json();
  return { ok: true, data: data as T };
}

async function postJson(
  url: string,
  method: "PATCH" | "POST",
  body: unknown,
): Promise<CommandResult> {
  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    return { ok: false, status: 0, error: "Network error" };
  }

  if (!response.ok) {
    let message = "Request failed";
    try {
      const errorBody = await response.json();
      message = errorBody?.error ?? message;
    } catch {
      // Response body wasn't JSON; keep the default message.
    }
    return { ok: false, status: response.status, error: message };
  }

  const data = await response.json();
  return { ok: true, id: data?.id };
}

export function corregirOperacion(
  operationId: string,
  cambios: Record<string, unknown>,
): Promise<CommandResult> {
  return postJson(`/api/remittance-operations/${operationId}`, "PATCH", {
    cambios,
  });
}

export function corregirBeneficiario(
  beneficiaryId: string,
  cambios: Record<string, unknown>,
): Promise<CommandResult> {
  return postJson(
    `/api/remittance-operations/beneficiaries/${beneficiaryId}`,
    "PATCH",
    { cambios },
  );
}

export function reasignarBeneficiario(
  beneficiaryId: string,
  targetOperationId: string,
): Promise<CommandResult> {
  return postJson(
    `/api/remittance-operations/beneficiaries/${beneficiaryId}/reassign`,
    "POST",
    { targetOperationId },
  );
}

export type AgregarBeneficiarioCommandResult =
  | { ok: true; id: string; complete: boolean }
  | { ok: false; status: number; error: string };

export async function agregarBeneficiario(
  operationId: string,
  datos: Record<string, unknown>,
): Promise<AgregarBeneficiarioCommandResult> {
  const response = await postJsonResult<{ id: string; complete: boolean }>(
    `/api/remittance-operations/${operationId}/beneficiaries`,
    "POST",
    { datos },
  );
  if (!response.ok) return response;
  return { ok: true, id: response.data.id, complete: response.data.complete };
}

export async function fetchOperationReceipts(
  operationId: string,
): Promise<FetchResult<OperationReceiptsRead>> {
  const result = await getJson(
    `/api/remittance-operations/${operationId}/receipts`,
  );
  if (!result.ok) return result;
  return {
    ok: true,
    data: (result.data as { receipts: OperationReceiptsRead }).receipts,
  };
}

export type VerifyDepositCommandResult =
  | { ok: true; result: VerifyDepositResult }
  | { ok: false; status: number; error: string };

export async function verifyDeposit(
  operationId: string,
  items: VerifyDepositItem[],
): Promise<VerifyDepositCommandResult> {
  const response = await postJsonResult<{ result: VerifyDepositResult }>(
    `/api/remittance-operations/${operationId}/verify`,
    "POST",
    { items },
  );
  if (!response.ok) return response;
  return { ok: true, result: response.data.result };
}

export type ForceVerifyDepositCommandResult =
  | { ok: true; newStatus: string }
  | { ok: false; status: number; error: string };

export async function forceVerifyDeposit(
  operationId: string,
  reason: string,
): Promise<ForceVerifyDepositCommandResult> {
  const response = await postJsonResult<{ newStatus: string }>(
    `/api/remittance-operations/${operationId}/force-verify`,
    "POST",
    { reason },
  );
  if (!response.ok) return response;
  return { ok: true, newStatus: response.data.newStatus };
}

export type DeliverOperationCommandResult =
  | { ok: true; newStatus: string; completedAt: string | null }
  | { ok: false; status: number; error: string };

export async function deliverOperation(
  operationId: string,
  evidence: DeliveryEvidenceRpc,
): Promise<DeliverOperationCommandResult> {
  const response = await postJsonResult<{ newStatus: string; completedAt: string | null }>(
    `/api/remittance-operations/${operationId}/deliver`,
    "POST",
    { evidence },
  );
  if (!response.ok) return response;
  return { ok: true, newStatus: response.data.newStatus, completedAt: response.data.completedAt };
}
