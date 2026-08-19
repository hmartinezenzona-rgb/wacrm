// ============================================================
// Which stages the delivery-proof panel attaches to.
//
// The proof panel is not a generic pipeline feature: it belongs to
// the remittance board, where "hand the customer the transfer
// screenshot" is a step in the process. Every other pipeline —
// including the seeded "Sales Pipeline" — must behave exactly as
// before, which is what pinning the behaviour to two specific
// stage ids buys.
//
// The ids come from the audit (doc 47), read from production:
//
//   Lista para transferir   f5cf87f8-b570-4d71-b6ea-a3cafd458c63
//   Entregada               1b36b34c-1bf1-4095-9a86-5ec5ff945d2b
//
// They are overridable by env because this repo is a template that
// other deployments run, and because hard-coding one business's
// UUIDs into a component is how a codebase stops being reusable.
// Before this file, no remittance-specific id appeared anywhere in
// `src/` — they lived only in the SQL migrations and in n8n. Keeping
// them in one named module means there is still exactly one place to
// look, and one place to change.
//
// Matching by stage NAME was considered and rejected: names are
// editable from the pipeline settings UI, so a rename would silently
// switch the feature off (or, worse, on for the wrong column).
// ============================================================

/**
 * The stage where a proof can be prepared. The panel appears on deals
 * sitting here and nowhere else.
 */
export const DELIVERY_PROOF_STAGE_ID =
  process.env.NEXT_PUBLIC_DELIVERY_PROOF_STAGE_ID ||
  "f5cf87f8-b570-4d71-b6ea-a3cafd458c63";

/**
 * The stage that triggers the send. Dropping a deal here with a proof
 * prepared is what starts `deliverDeal`; dropping any other deal here
 * is untouched, pre-existing behaviour.
 */
export const DELIVERED_STAGE_ID =
  process.env.NEXT_PUBLIC_DELIVERED_STAGE_ID ||
  "1b36b34c-1bf1-4095-9a86-5ec5ff945d2b";

/** Can a proof be prepared on a deal in this stage? */
export function acceptsDeliveryProof(stageId: string | null | undefined): boolean {
  return !!stageId && stageId === DELIVERY_PROOF_STAGE_ID;
}

/** Is this the stage whose arrival sends the proof? */
export function isDeliveredStage(stageId: string | null | undefined): boolean {
  return !!stageId && stageId === DELIVERED_STAGE_ID;
}
