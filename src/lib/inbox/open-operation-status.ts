// Which operation status the conversation list shows on a row's chip.
// Pure, no I/O. The status is the operations panel's own projection
// (`effectiveStatus`), so the chip says exactly what the panel says.

import {
  effectiveStatus,
  type EffectiveStatus,
} from "@/lib/remittance-operations/effective-status";
import type { RemittanceOperationStatus } from "@/lib/remittance-operations/types";

/** The fields needed from a board row (`crm_tablero_operaciones`). */
export interface OpenOperationInput {
  conversationId: string;
  status: string;
  beneficiariesComplete: boolean | null;
  createdAt: string;
}

const OPEN_STATUSES: ReadonlySet<string> = new Set<RemittanceOperationStatus>([
  "collecting_information",
  "awaiting_deposit",
  "deposit_received",
  "deposit_verification",
  "ready_to_transfer",
  "transferring",
  "incident",
]);

/**
 * Selection rule: with several open operations in one conversation, the one
 * whose effective status needs the team soonest wins (index 0 = most urgent);
 * ties go to the most recently created operation.
 */
const URGENCY: ReadonlyArray<EffectiveStatus> = [
  "incident",
  "ready_to_transfer",
  "deposit_verification",
  "deposit_received",
  "awaiting_beneficiary",
  "transferring",
  "awaiting_deposit",
  "collecting_information",
];

function rank(status: EffectiveStatus): number {
  const i = URGENCY.indexOf(status);
  return i === -1 ? URGENCY.length : i;
}

/** Effective status of the most relevant open operation, or null if none is open. */
export function pickOpenOperationStatus(
  operations: ReadonlyArray<OpenOperationInput>,
): EffectiveStatus | null {
  let best: { status: EffectiveStatus; createdAt: string } | null = null;
  for (const o of operations) {
    if (!OPEN_STATUSES.has(o.status)) continue;
    const status = effectiveStatus({
      status: o.status as RemittanceOperationStatus,
      isHistory: false,
      // Same default as the panel's read model (`?? false`).
      beneficiariesComplete: o.beneficiariesComplete ?? false,
    });
    if (
      !best ||
      rank(status) < rank(best.status) ||
      (rank(status) === rank(best.status) && o.createdAt > best.createdAt)
    ) {
      best = { status, createdAt: o.createdAt };
    }
  }
  return best ? best.status : null;
}

/** conversationId -> chip status; conversations without an open operation are absent. */
export function openOperationStatusByConversation(
  operations: ReadonlyArray<OpenOperationInput>,
): Map<string, EffectiveStatus> {
  const byConversation = new Map<string, OpenOperationInput[]>();
  for (const o of operations) {
    const list = byConversation.get(o.conversationId);
    if (list) list.push(o);
    else byConversation.set(o.conversationId, [o]);
  }
  const result = new Map<string, EffectiveStatus>();
  for (const [id, list] of byConversation) {
    const status = pickOpenOperationStatus(list);
    if (status) result.set(id, status);
  }
  return result;
}
