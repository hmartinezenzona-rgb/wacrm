// ============================================================
// Moving a deal to "Entregada", with or without a delivery proof.
//
// This is the order-of-operations that the audit (doc 47) argued
// about, in one place and testable without a browser. Every side
// effect arrives as an injected dependency, so the tests assert on
// what was called, in what order, and — just as important — what
// was NOT called.
//
// The rule the whole module exists to protect:
//
//   NO PROOF  →  exactly today's behaviour. One stage update,
//                nothing else. No permission probe, no window
//                query, no upload, no send. A deal without a proof
//                must not be able to tell this code was deployed.
//
//   PROOF     →  send the evidence first, and only persist the
//                stage once the customer actually has it.
//
// Why send-then-persist and not the reverse: the stage change fires
// `deals_stage_notify` → n8n → the `remesa_completada` template, a
// path with no retry, no log and no watchdog. Anything that must be
// seen to fail has to fail while the operator is still looking at
// the screen. The one exception is a closed 24-hour window, which
// the operator resolves explicitly (`skipProof`) rather than being
// blocked by — measured at 1 delivery in 108.
// ============================================================

import {
  draftBelongsTo,
  validateProofFile,
  type DeliveryProofDraft,
} from "@/lib/pipelines/delivery-proof";
import { DELIVERY_PROOF_STAGE_ID } from "@/lib/pipelines/delivery-stages";

export type DeliveryBlock =
  /** Caller lacks `send-messages`. Nothing was uploaded or sent. */
  | "permission"
  /** The deal has no conversation, so there is nobody to send to. */
  | "no-conversation"
  /** The draft in hand belongs to a different deal — never send it. */
  | "draft-mismatch"
  /** The file failed revalidation at confirm time. */
  | "invalid-file";

export type DeliveryResult =
  /** Proof delivered (or skipped) and the deal is in Entregada. */
  | { status: "delivered"; proofSent: boolean; wamid?: string }
  /** Refused before any side effect. */
  | { status: "blocked"; reason: DeliveryBlock }
  /**
   * The window shut between preparing and confirming. Nothing was
   * uploaded or sent; the operator decides whether to deliver anyway.
   */
  | { status: "window-closed" }
  /** Upload or send failed, nothing reached the customer. The deal did NOT move. */
  | { status: "failed"; phase: "upload" | "send"; message: string }
  /**
   * Meta accepted the image but WaCRM could not record it. The customer
   * HAS it. Recovery is the stage update alone — never a second send.
   */
  | { status: "sent-not-recorded"; message: string; wamid: string }
  /**
   * The send request never came back. Possibly delivered, possibly not.
   * Nothing is cleaned up and nothing is retried automatically; the
   * operator has to look at the conversation.
   */
  | { status: "unconfirmed"; message: string }
  /**
   * Another session moved this deal out of "Lista para transferir"
   * between preparing the proof and confirming it. Nothing was sent.
   */
  | { status: "stale-stage" }
  /**
   * The worst case, and the reason `sentWamid` exists: the customer
   * HAS the proof but the stage update failed. Retrying must move the
   * stage only — never re-send the image.
   */
  | { status: "stage-failed"; message: string; proofSent: boolean; wamid?: string }
  /** A delivery for this deal is already in flight. */
  | { status: "busy" };

export interface SendProofArgs {
  conversationId: string;
  mediaUrl: string;
  /** Empty string when the operator wrote no note. */
  caption: string;
}

/**
 * What came back from the send endpoint. The three failure shapes are
 * NOT interchangeable, and collapsing them is how a customer ends up
 * with the same screenshot twice:
 *
 *   not-sent          Meta refused, or we never got that far. Nothing
 *                     reached the customer — clean up and retry.
 *
 *   sent-not-recorded Meta ACCEPTED it and WaCRM then failed to save
 *                     the row (`db_error` + a wamid). The customer has
 *                     the image. Never re-send, never delete the object
 *                     it is served from.
 *
 *   unconfirmed       The request itself failed — network dropped, the
 *                     response was lost. We genuinely do not know. Treat
 *                     as possibly-delivered and make the operator look.
 */
export type SendProofOutcome =
  | { ok: true; wamid?: string }
  | { ok: false; outcome: "not-sent"; message: string }
  | { ok: false; outcome: "sent-not-recorded"; message: string; wamid: string }
  | { ok: false; outcome: "unconfirmed"; message: string };

export interface DeliveryDeps {
  /** `useCan("send-messages")`. Checked before anything leaves the browser. */
  canSend(): boolean;
  /** Fresh 24-hour window check — the prepared draft may be minutes old. */
  isWindowOpen(conversationId: string): Promise<boolean>;
  /**
   * The deal's stage as the database has it right now. Re-read
   * immediately before the first irreversible effect, because the
   * in-process lock only covers this browser tab: another operator, or
   * n8n, may have moved the deal since the drag started. Returning
   * `null` (deal gone, or the read failed) also aborts — fail closed.
   */
  readStage(dealId: string): Promise<string | null>;
  /** Upload under the generic name; returns the public URL Meta will fetch. */
  uploadProof(
    file: File,
    uploadName: string,
  ): Promise<{ publicUrl: string; path: string }>;
  /** `POST /api/whatsapp/send` with `message_type: "image"`. */
  sendProof(args: SendProofArgs): Promise<SendProofOutcome>;
  /** Best-effort GC of an object whose send failed. Never throws. */
  discardUpload(path: string): Promise<void>;
  /** The one write this module makes: `deals.stage_id = Entregada`. */
  moveToDelivered(dealId: string): Promise<{ ok: true } | { ok: false; message: string }>;
}

export interface DeliveryRequest {
  dealId: string;
  conversationId: string | null | undefined;
  /** `null` means no proof was prepared — today's path, untouched. */
  draft: DeliveryProofDraft | null;
  /**
   * The operator answered "deliver without sending the proof", which
   * is the escape hatch for a closed 24-hour window. The image is not
   * uploaded and not sent; the final template still goes out through
   * n8n because a template crosses a closed window.
   */
  skipProof?: boolean;
  /**
   * True when this delivery was confirmed from a dialog that EXISTED
   * because a proof was prepared.
   *
   * It is the difference between "deliver this deal, it has no proof"
   * and "deliver this deal WITH the proof I just looked at". If the
   * draft has vanished by the time the confirmation lands — another
   * session moved the deal and `pruneStaleDrafts` dropped it — the
   * second must NOT silently become the first. Found in the manual
   * gate (M-10): the dialog was still promising to send a capture
   * while its button had quietly become a plain "mark delivered".
   */
  expectsProof?: boolean;
}

// ---------------------------------------------------------------
// In-flight guard
// ---------------------------------------------------------------

/**
 * One delivery per deal at a time. Two drags, a double click, or a
 * click racing a drag all collapse onto the first run; the losers get
 * `busy` without touching Storage, Meta or the database.
 *
 * Keyed by deal, not global: two operators delivering two different
 * remittances must not queue behind each other.
 */
const inFlight = new Map<string, Promise<DeliveryResult>>();

/** Whether a delivery is currently running for this deal. */
export function isDeliveryInFlight(dealId: string): boolean {
  return inFlight.has(dealId);
}

/** Test seam — drops any in-flight bookkeeping. */
export function resetDeliveryLocks(): void {
  inFlight.clear();
}

/**
 * Run a delivery, refusing to start a second one for the same deal.
 *
 * The promise is registered synchronously, before the first `await`,
 * so two calls in the same tick cannot both get past the check.
 */
export function deliverDeal(
  request: DeliveryRequest,
  deps: DeliveryDeps,
): Promise<DeliveryResult> {
  if (inFlight.has(request.dealId)) {
    return Promise.resolve({ status: "busy" });
  }
  const run = execute(request, deps).finally(() => {
    inFlight.delete(request.dealId);
  });
  inFlight.set(request.dealId, run);
  return run;
}

// ---------------------------------------------------------------
// The sequence
// ---------------------------------------------------------------

async function execute(
  request: DeliveryRequest,
  deps: DeliveryDeps,
): Promise<DeliveryResult> {
  const { dealId, conversationId, draft, skipProof, expectsProof } = request;

  // ---- The proof this delivery was about has vanished. ------------
  // Ahead of every other branch, including the no-proof path it would
  // otherwise fall into. A confirmation that was shown with a
  // screenshot on it must never resolve as an ordinary delivery.
  if (expectsProof && !draft) {
    return { status: "stale-stage" };
  }

  // ---- No proof: today's path, and nothing else. -----------------
  // Deliberately ahead of every check below. A deal without a proof
  // must produce one call — the stage update — exactly as it did
  // before this feature existed.
  if (!draft || skipProof) {
    const moved = await deps.moveToDelivered(dealId);
    return moved.ok
      ? { status: "delivered", proofSent: false }
      : { status: "stage-failed", message: moved.message, proofSent: false };
  }

  // A draft prepared on another deal must never be sent here. The map
  // is keyed by deal id, so this should be unreachable — which is why
  // it is checked: the failure it prevents is a customer receiving
  // someone else's transfer screenshot.
  if (!draftBelongsTo(draft, dealId)) {
    return { status: "blocked", reason: "draft-mismatch" };
  }

  // ---- Already sent: this is a retry of the stage update. ---------
  // Set by a previous run that got the image through and then failed
  // to persist the stage. Re-sending would give the customer the same
  // screenshot twice.
  if (draft.sentWamid) {
    const moved = await deps.moveToDelivered(dealId);
    return moved.ok
      ? { status: "delivered", proofSent: true, wamid: draft.sentWamid }
      : {
          status: "stage-failed",
          message: moved.message,
          proofSent: true,
          wamid: draft.sentWamid,
        };
  }

  // ---- Gates, cheapest first, all before any side effect. ---------
  if (!deps.canSend()) {
    return { status: "blocked", reason: "permission" };
  }
  if (!conversationId) {
    return { status: "blocked", reason: "no-conversation" };
  }

  const check = await validateProofFile(draft.file);
  if (!check.ok) {
    return { status: "blocked", reason: "invalid-file" };
  }

  // Re-checked here and not only in the panel: the draft may have been
  // sitting open while the window ran out.
  if (!(await deps.isWindowOpen(conversationId))) {
    return { status: "window-closed" };
  }

  // ---- Last gate before anything irreversible ----------------------
  // The lock above is per-tab. It cannot see a second browser, another
  // operator, or n8n. Re-reading the stage here is not a real mutex —
  // two sessions can still pass this check together — but it closes
  // the common case for one cheap indexed read: someone else already
  // moved this deal on while the proof sat prepared.
  const stage = await deps.readStage(dealId).catch(() => null);
  if (stage !== DELIVERY_PROOF_STAGE_ID) {
    return { status: "stale-stage" };
  }

  // ---- Upload ------------------------------------------------------
  let uploaded: { publicUrl: string; path: string };
  try {
    uploaded = await deps.uploadProof(draft.file, check.uploadName);
  } catch (err) {
    return { status: "failed", phase: "upload", message: errorMessage(err) };
  }

  // ---- Send --------------------------------------------------------
  let sent: SendProofOutcome;
  try {
    sent = await deps.sendProof({
      conversationId,
      mediaUrl: uploaded.publicUrl,
      caption: draft.caption.trim(),
    });
  } catch (err) {
    // A throw means no response came back at all. We cannot tell
    // whether Meta got it, so we assume the expensive possibility.
    sent = { ok: false, outcome: "unconfirmed", message: errorMessage(err) };
  }

  if (!sent.ok) {
    switch (sent.outcome) {
      case "sent-not-recorded":
        // The customer HAS the image, and it is being served from the
        // object we just uploaded. Deleting it would break the message
        // they already received; re-sending would deliver it twice.
        return {
          status: "sent-not-recorded",
          message: sent.message,
          wamid: sent.wamid,
        };

      case "unconfirmed":
        // Might be delivered. Leave the object alone for the same
        // reason as above, and make a human look before retrying.
        return { status: "unconfirmed", message: sent.message };

      case "not-sent":
      default:
        // Nothing reached the customer — take the object back out of
        // the public bucket rather than leaving it there forever.
        // Best-effort: a failed cleanup is a storage nit, not something
        // to report over the send error the operator needs to read.
        await deps.discardUpload(uploaded.path).catch(() => {});
        return { status: "failed", phase: "send", message: sent.message };
    }
  }

  // ---- Persist the stage ------------------------------------------
  // Past this line the customer has the proof. A failure here is
  // recoverable but must NOT re-send: the caller records `wamid` on
  // the draft and offers a stage-only retry.
  const moved = await deps.moveToDelivered(dealId);
  if (!moved.ok) {
    return {
      status: "stage-failed",
      message: moved.message,
      proofSent: true,
      wamid: sent.wamid,
    };
  }

  return { status: "delivered", proofSent: true, wamid: sent.wamid };
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
