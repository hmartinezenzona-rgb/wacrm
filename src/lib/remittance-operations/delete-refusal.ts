// ============================================================
// Maps the refusal of `crm_eliminar_operacion` (SQLSTATE 22023, passed through
// by `rpcErrorResponse` as a 400 `{ error }`, or a 403 from the role gate) to
// a message key, so the panel says WHY a delete was refused instead of the raw
// server text. A message that matches nothing returns null and the caller
// shows the server text as is (same contract as `delivery-refusal.ts`).
// ============================================================

/** Key under `Inbox.operationsPanel.closing.deleteRefusal`. */
export type DeleteRefusalKey = "alreadyClosed" | "verifiedDeposit" | "notAdmin";

export function parseDeleteRefusal(message: string, status: number): DeleteRefusalKey | null {
  if (status === 403 || message.includes("only an owner or admin can delete an operation")) {
    return "notAdmin";
  }
  if (/an operation that is (cancelled|completed) cannot be deleted/.test(message)) {
    return "alreadyClosed";
  }
  if (message.includes("an operation with a verified deposit cannot be deleted")) {
    return "verifiedDeposit";
  }
  return null;
}
