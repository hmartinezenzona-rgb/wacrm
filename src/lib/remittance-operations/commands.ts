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
  notify = true,
): Promise<VerifyDepositCommandResult> {
  const response = await postJsonResult<{ result: VerifyDepositResult }>(
    `/api/remittance-operations/${operationId}/verify`,
    "POST",
    { items, notify },
  );
  if (!response.ok) return response;
  return { ok: true, result: response.data.result };
}

export type ForceVerifyDepositCommandResult =
  | { ok: true; newStatus: string }
  | { ok: false; status: number; error: string };

export async function forceVerifyDeposit(
  operationId: string,
  notify = true,
): Promise<ForceVerifyDepositCommandResult> {
  const response = await postJsonResult<{ newStatus: string }>(
    `/api/remittance-operations/${operationId}/force-verify`,
    "POST",
    { notify },
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
  notify = true,
): Promise<DeliverOperationCommandResult> {
  const response = await postJsonResult<{ newStatus: string; completedAt: string | null }>(
    `/api/remittance-operations/${operationId}/deliver`,
    "POST",
    { evidence, notify },
  );
  if (!response.ok) return response;
  return { ok: true, newStatus: response.data.newStatus, completedAt: response.data.completedAt };
}

export interface BeneficiaryProofEvidenceRpc {
  wamid: string;
  path?: string;
  caption?: string;
}

export type RegisterBeneficiaryProofCommandResult =
  | { ok: true; registered: boolean; missing: number }
  | { ok: false; status: number; error: string };

/** `crm_registrar_prueba_beneficiario`, via the per-beneficiary proof
 *  endpoint (migration 143) — records one beneficiary's delivery proof
 *  ahead of the single `deliverOperation` call, for a 2+ beneficiary
 *  remesa (panel per-beneficiary delivery proof, P3). */
export async function registerBeneficiaryProof(
  operationId: string,
  beneficiaryId: string,
  evidence: BeneficiaryProofEvidenceRpc,
): Promise<RegisterBeneficiaryProofCommandResult> {
  const response = await postJsonResult<{ registered: boolean; missing: number }>(
    `/api/remittance-operations/${operationId}/beneficiaries/${beneficiaryId}/proof`,
    "POST",
    { evidence },
  );
  if (!response.ok) return response;
  return { ok: true, registered: response.data.registered, missing: response.data.missing };
}

export type ManualCloseCommandResult =
  | { ok: true; newStatus: string; completedAt: string | null }
  | { ok: false; status: number; error: string };

/** `crm_cerrar_operacion_manual` (migrations 190/191): completes a verified
 *  remesa; the customer is messaged only when `notify` is true (default
 *  false). Owner/admin only; no reason is asked for. `deliveryMethod` (migration
 *  196) names the service when the remesa has no beneficiary yet. */
export async function cerrarOperacionManual(
  operationId: string,
  notify = false,
  deliveryMethod?: string,
): Promise<ManualCloseCommandResult> {
  const response = await postJsonResult<{ newStatus: string; completedAt: string | null }>(
    `/api/remittance-operations/${operationId}/close-manual`,
    "POST",
    deliveryMethod ? { notify, deliveryMethod } : { notify },
  );
  if (!response.ok) return response;
  return { ok: true, newStatus: response.data.newStatus, completedAt: response.data.completedAt };
}

export type SetComboCostoCommandResult =
  | { ok: true; costGyd: number | null }
  | { ok: false; status: number; error: string };

/** `crm_set_combo_costo` (migration 208): what a combo cost, in GYD; `null`
 *  clears it. Owner/admin only. */
export async function setComboCosto(
  operationId: string,
  costGyd: number | null,
): Promise<SetComboCostoCommandResult> {
  const response = await postJsonResult<{ costGyd: number | null }>(
    `/api/remittance-operations/${operationId}/combo-cost`,
    "POST",
    { costGyd },
  );
  if (!response.ok) return response;
  return { ok: true, costGyd: response.data.costGyd ?? null };
}

export type ChangeServiceCommandResult =
  | { ok: true; service: string; changed: boolean }
  | { ok: false; status: number; error: string };

/** `crm_cambiar_servicio` (migration 222): switches an open operation to another service. The quote is recalculated
 *  and the recipients that do not fit are retired; the customer is not messaged. */
export async function cambiarServicio(
  operationId: string,
  servicio: string,
): Promise<ChangeServiceCommandResult> {
  const response = await postJsonResult<{ service: string; changed: boolean }>(
    `/api/remittance-operations/${operationId}/service`,
    "POST",
    { servicio },
  );
  if (!response.ok) return response;
  return { ok: true, service: response.data.service, changed: response.data.changed };
}

export type DeleteOperationCommandResult =
  | { ok: true; newStatus: string }
  | { ok: false; status: number; error: string };

/** `crm_eliminar_operacion` (migrations 190/191): soft-deletes a remesa
 *  (status cancelled). Owner/admin only; no reason is asked for. */
export async function eliminarOperacion(
  operationId: string,
): Promise<DeleteOperationCommandResult> {
  const response = await postJsonResult<{ newStatus: string }>(
    `/api/remittance-operations/${operationId}/delete`,
    "POST",
    {},
  );
  if (!response.ok) return response;
  return { ok: true, newStatus: response.data.newStatus };
}
