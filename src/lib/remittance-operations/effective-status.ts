// ============================================================
// The panel's readiness projection over `RemittanceOperationRead`
// (migration 102). The raw `status` column alone no longer tells the
// operator whether an operation is actually actionable: a deposit-verified
// operation with incomplete beneficiary data cannot be delivered
// (`crm_entregar_operacion` now rejects it), so the panel must show
// "waiting for beneficiary" instead of a misleading "ready to transfer".
// Pure, no I/O — same shape as `read-model.ts`.
// ============================================================

import type { RemittanceOperationStatus } from "./types";

/** `RemittanceOperationStatus` plus the one synthetic status this
 *  projection can produce that isn't a real DB value. */
export type EffectiveStatus = RemittanceOperationStatus | "awaiting_beneficiary";

/** The three fields `effectiveStatus` needs — narrower than the full
 *  `RemittanceOperationRead` so callers (and tests) don't have to build a
 *  whole operation just to project its status. */
export interface EffectiveStatusInput {
  status: RemittanceOperationStatus;
  isHistory: boolean;
  beneficiariesComplete: boolean;
}

/**
 * Projects an operation's raw `status` into what the panel should show:
 *
 *   - `isHistory` (or an already-`completed` row) always wins: `completed`.
 *   - `incident` and `deposit_verification` are shown as-is — beneficiary
 *     completeness doesn't change what the operator needs to do there.
 *   - Once the deposit is verified (`ready_to_transfer` / `transferring`),
 *     incomplete beneficiary data demotes the status to
 *     `awaiting_beneficiary` — delivery is blocked until it's fixed.
 *   - Before the deposit is verified (`collecting_information` /
 *     `awaiting_deposit` / `deposit_received`), complete beneficiary data
 *     promotes the status to `awaiting_deposit` — nothing left to collect
 *     except the money.
 *   - Anything else (currently just `awaiting_deposit` itself) is
 *     unchanged.
 */
export function effectiveStatus(op: EffectiveStatusInput): EffectiveStatus {
  if (op.isHistory || op.status === "completed") return "completed";

  if (op.status === "incident" || op.status === "deposit_verification") {
    return op.status;
  }

  if (op.status === "ready_to_transfer" || op.status === "transferring") {
    return op.beneficiariesComplete ? op.status : "awaiting_beneficiary";
  }

  if (
    op.status === "collecting_information" ||
    op.status === "awaiting_deposit" ||
    op.status === "deposit_received"
  ) {
    return op.beneficiariesComplete ? "awaiting_deposit" : op.status;
  }

  return op.status;
}
