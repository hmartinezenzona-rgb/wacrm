// ============================================================
// Browser-side helpers for the remesa operations panel correction and
// reassignment actions. Thin fetch wrappers over the PATCH/POST API
// routes — no business logic here, just request shaping and a uniform
// result type for the UI to render.
// ============================================================

export type CommandResult =
  | { ok: true; id?: string }
  | { ok: false; status: number; error: string };

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
