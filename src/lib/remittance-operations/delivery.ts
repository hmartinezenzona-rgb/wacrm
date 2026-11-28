// ============================================================
// Bridge between the browser-side delivery pipeline
// (`@/lib/pipelines/deliver-with-proof`) and `crm_entregar_operacion`'s
// `p_evidence` shape (migration 101).
//
// The two live at different altitudes on purpose: `DeliveryEvidence` is
// "what happened" (two booleans plus whatever the send produced),
// `DeliveryEvidenceRpc` is "what the RPC's CHECK/validation expects" (one
// closed enum). Keeping the mapping in one small, pure function is what
// lets both sides change independently without the mode derivation
// drifting out of sync with the database's own three-way CHECK.
// ============================================================

import type { DeliveryEvidence } from "@/lib/pipelines/deliver-with-proof";

export type DeliveryEvidenceMode = "proof_sent" | "no_proof" | "skip_proof";

export interface DeliveryEvidenceRpc {
  mode: DeliveryEvidenceMode;
  wamid?: string;
  path?: string;
}

/**
 * `proofSent` wins over `skipProof` when (defensively) both are set —
 * `deliverDeal` never produces that combination, but the mode a proof
 * actually sent must never be reported to the database as "skipped".
 */
export function evidenceToRpc(evidence: DeliveryEvidence): DeliveryEvidenceRpc {
  const mode: DeliveryEvidenceMode = evidence.proofSent
    ? "proof_sent"
    : evidence.skipProof
      ? "skip_proof"
      : "no_proof";

  const result: DeliveryEvidenceRpc = { mode };
  if (evidence.wamid) result.wamid = evidence.wamid;
  if (evidence.path) result.path = evidence.path;
  return result;
}
