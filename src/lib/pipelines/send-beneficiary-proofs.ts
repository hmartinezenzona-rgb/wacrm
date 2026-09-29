// ============================================================
// Sending N delivery proofs — one per current beneficiary — before the
// single completion call (panel per-beneficiary delivery proof, P3).
//
// A remesa with 2+ current beneficiaries gets one proof image per
// beneficiary, in order. For each: upload + send exactly as the
// single-proof pipeline (the same `uploadProof`/`sendProof` deps
// `deliver-with-proof.ts` uses), then record it via
// `crm_registrar_prueba_beneficiario` (migration 143). Only once every
// beneficiary has been sent and recorded does the caller run the
// existing `deliverDeal` ONCE, with the LAST proof's evidence — see
// `complete-transfer-container.tsx`.
//
// Kept separate from `deliver-with-proof.ts` on purpose: that module's
// job is "one deal, one proof, one stage flip", and every rule in it
// (window check, stage re-read, the in-flight lock) is about that single
// irreversible flip. This module never flips a stage and never checks
// the window/stage itself — the caller runs those once, before calling
// in, exactly as it does today for the single-proof path. Its only job
// is "send and record each image, in order, without ever re-sending one
// that already reached the customer".
//
// Retry-safety: a beneficiary whose `sentWamid` is already set has
// already reached the customer. Retrying NEVER re-uploads or re-sends
// it — only the register call runs again, which is safe because
// `crm_registrar_prueba_beneficiario` is idempotent per (beneficiary,
// wamid) (migration 143).
// ============================================================

import {
  proofUploadName,
  validateProofFile,
  type ProofFileLike,
  type ProofImageKind,
} from "@/lib/pipelines/delivery-proof";
import type { SendProofArgs, SendProofOutcome } from "@/lib/pipelines/deliver-with-proof";

export interface BeneficiaryProofItem {
  beneficiaryId: string;
  file: File;
  kind: ProofImageKind;
  /** Empty string when the operator wrote no note (non-Zelle beneficiaries
   *  never show the caption field at all). */
  caption: string;
  /** Set once this beneficiary's image has reached the customer — the
   *  retry marker: its presence means "do not send this again". */
  sentWamid?: string;
  /** The storage path the image was uploaded to, carried alongside
   *  `sentWamid` so the final `deliverDeal` call can still report it on
   *  the operation-level `delivery_proof_path` (backward compatibility:
   *  P2's doc, "the operation-level columns stay, holding the last
   *  proof"). */
  sentPath?: string;
}

export interface RegisterProofOutcome {
  ok: boolean;
  /** Current beneficiaries still missing a proof, per
   *  `crm_registrar_prueba_beneficiario`'s response. Informational only —
   *  this module does not act on it. */
  missing?: number;
  message?: string;
}

export interface BeneficiaryProofDeps {
  conversationId: string;
  /** Upload under the generic name; returns the public URL Meta will fetch.
   *  Identical contract to `DeliveryDeps.uploadProof`. */
  uploadProof(file: File, uploadName: string): Promise<{ publicUrl: string; path: string }>;
  /** `POST /api/whatsapp/send` with `message_type: "image"` — the exact
   *  same `sendProofImage` the single-proof pipeline calls. */
  sendProof(args: SendProofArgs): Promise<SendProofOutcome>;
  /** Best-effort GC of an object whose send failed. Never throws. */
  discardUpload(path: string): Promise<void>;
  /** `crm_registrar_prueba_beneficiario(operation, beneficiary, evidence)`. */
  registerProof(
    beneficiaryId: string,
    evidence: { wamid: string; path?: string; caption?: string },
  ): Promise<RegisterProofOutcome>;
}

export type SendBeneficiaryProofsResult =
  | { status: "sent"; items: BeneficiaryProofItem[] }
  | {
      status: "failed";
      beneficiaryId: string;
      phase: "invalid-file" | "upload" | "send" | "register";
      message: string;
      /** Every item, in order, reflecting progress so far — the caller
       *  persists this back onto its per-beneficiary draft state so a
       *  retry sees which ones are already sent. */
      items: BeneficiaryProofItem[];
    };

/**
 * Send and record each beneficiary's proof, in the order given. Stops at
 * the first failure — nothing after it runs.
 */
export async function sendBeneficiaryProofs(
  items: readonly BeneficiaryProofItem[],
  deps: BeneficiaryProofDeps,
): Promise<SendBeneficiaryProofsResult> {
  const next: BeneficiaryProofItem[] = items.map((item) => ({ ...item }));

  for (const item of next) {
    if (!item.sentWamid) {
      const check = await validateProofFile(item.file as unknown as ProofFileLike);
      if (!check.ok) {
        return {
          status: "failed",
          beneficiaryId: item.beneficiaryId,
          phase: "invalid-file",
          message: `invalid file: ${check.reason}`,
          items: next,
        };
      }

      let uploaded: { publicUrl: string; path: string };
      try {
        uploaded = await deps.uploadProof(item.file, proofUploadName(check.kind));
      } catch (err) {
        return {
          status: "failed",
          beneficiaryId: item.beneficiaryId,
          phase: "upload",
          message: errorMessage(err),
          items: next,
        };
      }

      let sent: SendProofOutcome;
      try {
        sent = await deps.sendProof({
          conversationId: deps.conversationId,
          mediaUrl: uploaded.publicUrl,
          caption: item.caption.trim(),
        });
      } catch (err) {
        // No response came back at all — we cannot tell whether the
        // customer got it. Same rule as the single-proof pipeline: treat
        // as possibly-delivered, do not mark it sent (so a retry can try
        // again), and do not touch the uploaded object.
        sent = { ok: false, outcome: "unconfirmed", message: errorMessage(err) };
      }

      if (!sent.ok) {
        if (sent.outcome === "not-sent") {
          // Nothing reached the customer — take the object back out of
          // the public bucket. Best-effort, same as the single-proof path.
          await deps.discardUpload(uploaded.path).catch(() => {});
        }
        if (sent.outcome === "sent-not-recorded") {
          // Meta accepted it despite the error — the customer HAS the
          // image. Capture the wamid so a retry never re-sends it, even
          // though this attempt is still reported as failed.
          item.sentWamid = sent.wamid;
          item.sentPath = uploaded.path;
        }
        return {
          status: "failed",
          beneficiaryId: item.beneficiaryId,
          phase: "send",
          message: sent.message,
          items: next,
        };
      }

      if (!sent.wamid) {
        // Defensive: the register RPC requires a wamid. A success with
        // none is not something the single-proof pipeline's own types
        // rule out, so treat it the same as a send failure rather than
        // calling the RPC with an empty string.
        return {
          status: "failed",
          beneficiaryId: item.beneficiaryId,
          phase: "send",
          message: "the send succeeded without a message id",
          items: next,
        };
      }

      item.sentWamid = sent.wamid;
      item.sentPath = uploaded.path;
    }

    const registered = await deps.registerProof(item.beneficiaryId, {
      wamid: item.sentWamid!,
      path: item.sentPath,
      caption: item.caption.trim() || undefined,
    });
    if (!registered.ok) {
      return {
        status: "failed",
        beneficiaryId: item.beneficiaryId,
        phase: "register",
        message: registered.message ?? "could not record this beneficiary's proof",
        items: next,
      };
    }
  }

  return { status: "sent", items: next };
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
