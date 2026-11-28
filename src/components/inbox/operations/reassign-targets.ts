import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

/** The RPC never returns these (see types.ts) — same defensive exclusion
 *  as `remittance-operation-card.tsx`. */
const TERMINAL_STATUSES: ReadonlyArray<string> = ["completed", "cancelled"];

/** Other open operations of the same conversation, offered as reassignment
 *  targets for `operation`'s beneficiaries. A combo recipient moves only to
 *  another combo, and nothing else moves into a combo
 *  (`crm_reasignar_beneficiario`, 212), so the list is split by service type. */
export function otherOpenOperationsFor(
  operation: RemittanceOperationRead,
  operations: RemittanceOperationRead[],
): { id: string; label: string }[] {
  const isCombo = operation.serviceType === "combo";
  return operations
    .filter(
      (candidate) =>
        candidate.id !== operation.id &&
        !TERMINAL_STATUSES.includes(candidate.status) &&
        (candidate.serviceType === "combo") === isCombo,
    )
    .map((candidate) => ({
      id: candidate.id,
      label: isCombo
        ? `${candidate.quotedSourceAmount ?? "?"} ${candidate.sourceCurrency ?? ""}`.trim()
        : `${candidate.quotedSourceAmount ?? "?"} ${candidate.sourceCurrency ?? ""} → ${candidate.destinationCurrency ?? ""}`,
    }));
}
