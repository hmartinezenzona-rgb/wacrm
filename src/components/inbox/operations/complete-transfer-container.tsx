"use client";

// ============================================================
// "Complete transfer" (panel-23) — completes a ready_to_transfer
// remittance straight from the operations panel, reusing the exact
// send-then-persist pipeline the pipelines board already runs
// (`deliverDeal`, panel-19/22): the screenshot reaches the customer
// BEFORE the operation is marked complete, because completion fires
// the "remesa completada" WhatsApp template with no retry and no
// watchdog.
//
// This container plugs the operations-panel endpoint
// (`crm_entregar_operacion` via `deliverOperation`/`evidenceToRpc`) into
// `deliverDeal` as its `moveToDelivered`, so the module that already
// carries every ordering/concurrency/evidence rule for a pipelines
// delivery enforces the same rules here. It holds its own single draft
// (not the board's per-deal map — there is exactly one operation open at
// a time in this card) and renders the presentational
// `CompleteTransferSection`.
// ============================================================

import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { toast } from "sonner";
import { createClient } from "@/lib/supabase/client";
import { useCan } from "@/hooks/use-can";
import { uploadAccountMedia, deleteAccountMedia } from "@/lib/storage/upload-media";
import { CHAT_MEDIA_BUCKET } from "@/components/inbox/message-composer";
import { fetchLastCustomerMessageAt } from "@/lib/inbox/last-customer-message";
import { sessionWindowFrom } from "@/lib/inbox/session-window";
import {
  pickPastedImage,
  validateProofFile,
  type ClipboardLike,
  type DeliveryProofDraft,
  type ProofImageKind,
  type ProofRejection,
} from "@/lib/pipelines/delivery-proof";
import {
  deliverDeal,
  type DeliveryDeps,
  type DeliveryResult,
} from "@/lib/pipelines/deliver-with-proof";
import { sendProofImage } from "@/lib/pipelines/send-proof-image";
import {
  sendBeneficiaryProofs,
  type BeneficiaryProofDeps,
  type BeneficiaryProofItem,
} from "@/lib/pipelines/send-beneficiary-proofs";
import { DELIVERY_PROOF_STAGE_ID } from "@/lib/pipelines/delivery-stages";
import { deliverOperation, registerBeneficiaryProof } from "@/lib/remittance-operations/commands";
import { evidenceToRpc } from "@/lib/remittance-operations/delivery";
import type { ConversationOperationsRead } from "@/lib/remittance-operations/types";
import { CompleteTransferSection, type CompleteTransferBanner } from "./complete-transfer-section";
import { CompleteTransferMultiSection, type CompleteTransferProofItem } from "./complete-transfer-multi-section";

/** A current beneficiary, as far as this container needs to know: which
 *  panel to render (and whether it shows the caption box) once there are
 *  2 or more — see the `beneficiaries.length >= 2` branch below. Kept
 *  deliberately narrow (no name) — same reasoning as the generic upload
 *  filename in `delivery-proof.ts`. */
export interface CompleteTransferBeneficiary {
  id: string;
  isZelle: boolean;
}

export interface CompleteTransferContainerProps {
  operationId: string;
  conversationId: string;
  /** Only Zelle transfers show the note field (the recipient's name never
   *  appears anywhere else once the screenshot is sent). Used for the
   *  0/1-beneficiary path only — see `beneficiaries` for 2+. */
  isZelle: boolean;
  /** The operation's current ('vigente') beneficiaries. With 2 or more,
   *  the panel switches to one proof (image + caption for Zelle) per
   *  beneficiary, sent and recorded in order before the single
   *  completion call (per-beneficiary delivery proof, P3). With 0 or 1,
   *  this is ignored and the panel behaves exactly as before, driven by
   *  `isZelle` alone. Defaults to `[]` so existing callers/tests that
   *  don't pass it keep the single-proof path unchanged. */
  beneficiaries?: CompleteTransferBeneficiary[];
  /** The delivery completed (or the operator dismissed this card's
   *  in-flight state) — the panel container refetches, which drops this
   *  operation out of the ready-to-transfer list. */
  onDone: () => void;
  onCancel: () => void;
}

export function CompleteTransferContainer({
  operationId,
  conversationId,
  isZelle,
  beneficiaries = [],
  onDone,
  onCancel,
}: CompleteTransferContainerProps) {
  const t = useTranslations("Inbox.operationsPanel.completeTransfer");
  const canSend = useCan("send-messages");
  const multiMode = beneficiaries.length >= 2;
  const [draft, setDraftState] = useState<DeliveryProofDraft | null>(null);
  const [beneficiaryDrafts, setBeneficiaryDraftsState] = useState<Record<string, DeliveryProofDraft>>({});
  const [skipChecked, setSkipChecked] = useState(false);
  const [busy, setBusy] = useState(false);
  const [banner, setBanner] = useState<CompleteTransferBanner | null>(null);
  // The last `skip` a run actually used — a plain (no-proof) stage
  // failure has no wamid to retry from, so "Retry" just repeats the
  // exact same attempt.
  const lastSkipRef = useRef(false);
  // `run` (below) is called from click handlers created inside
  // `handleResult`, which can outlive the render that created them (a
  // stage-failed retry, for instance, must see the `sentWamid` a LATER
  // render stamped onto the draft, not the one `handleResult` closed
  // over). Mirroring every draft/busy update into a ref, read by `run`
  // instead of the state variable, makes that correct regardless of
  // which render's closures end up running.
  const draftRef = useRef<DeliveryProofDraft | null>(null);
  const busyRef = useRef(false);
  // Same reasoning as `draftRef`, for the 2+-beneficiary map: a retry
  // action built inside `handleMultiDeliverResult` must see whichever
  // beneficiaries a LATER render marked as sent, not the map the render
  // that built the closure captured.
  const beneficiaryDraftsRef = useRef<Record<string, DeliveryProofDraft>>({});

  const setDraft = useCallback(
    (updater: DeliveryProofDraft | null | ((prev: DeliveryProofDraft | null) => DeliveryProofDraft | null)) => {
      setDraftState((prev) => {
        const next = typeof updater === "function" ? updater(prev) : updater;
        draftRef.current = next;
        return next;
      });
    },
    [],
  );

  const clearDraft = useCallback(() => {
    setDraft((prev) => {
      if (prev) URL.revokeObjectURL(prev.previewUrl);
      return null;
    });
  }, [setDraft]);

  const handleFileAccepted = useCallback(
    (file: File, kind: ProofImageKind) => {
      setDraft((prev) => {
        if (prev) URL.revokeObjectURL(prev.previewUrl);
        return {
          dealId: operationId,
          file,
          kind,
          previewUrl: URL.createObjectURL(file),
          caption: prev?.caption ?? "",
        };
      });
      setBanner(null);
    },
    [operationId, setDraft],
  );

  const handleFileRejected = useCallback(
    // `DeliveryProofPanel` already narrows this to one of `ProofRejection`'s
    // four reasons; a single generic message is enough here — the panel's
    // own picker prevents re-submitting the same bad file blind.
    (reason: ProofRejection) => {
      void reason;
      setBanner({ kind: "error", text: t("blocked") });
    },
    [t],
  );

  // The same accept path `DeliveryProofPanel` runs internally
  // (validate-then-accept/reject), exposed here so the document-level
  // paste listener below can drive it too.
  const acceptPastedImage = useCallback(
    async (file: File) => {
      const result = await validateProofFile(file);
      if (result.ok) handleFileAccepted(file, result.kind);
      else handleFileRejected(result.reason);
    },
    [handleFileAccepted, handleFileRejected],
  );

  // Paste without clicking first: works anywhere on the page while this
  // section is mounted, not just when the drop zone or caption textarea
  // happens to have focus. `event.defaultPrevented` skips a paste the
  // panel's own onPaste already handled (it calls preventDefault only when
  // it found an image) — without that guard, a paste over the drop zone
  // would attach the same file twice as the native event bubbles here. A
  // paste carrying no image (e.g. plain text into the caption) is left
  // alone either way, same contract as the panel's own handler.
  //
  // Skipped entirely in `multiMode`: with 2+ drop zones on screen there is
  // no single "the" draft a document-wide paste could attach to. Each
  // panel's own `onPaste` (wired by `DeliveryProofPanel` itself) still
  // works normally when that panel's drop zone or caption box has focus.
  useEffect(() => {
    if (multiMode) return;

    function handleDocumentPaste(event: ClipboardEvent) {
      if (event.defaultPrevented) return;
      const image = pickPastedImage(event.clipboardData as unknown as ClipboardLike);
      if (!image) return;
      event.preventDefault();
      void acceptPastedImage(image);
    }

    document.addEventListener("paste", handleDocumentPaste);
    return () => document.removeEventListener("paste", handleDocumentPaste);
  }, [acceptPastedImage, multiMode]);

  const handleCaptionChange = useCallback(
    (caption: string) => {
      setDraft((prev) => (prev ? { ...prev, caption } : prev));
    },
    [setDraft],
  );

  // ---------------------------------------------------------------
  // 2+ beneficiaries: one draft per beneficiary, same shape
  // (`DeliveryProofDraft`) as the single-draft path above, keyed by
  // beneficiary id rather than held as one value. `dealId` still carries
  // the OPERATION id on every entry (not the beneficiary id) — consistent
  // with what `DeliveryProofDraft.dealId` means everywhere else.
  // ---------------------------------------------------------------

  const setBeneficiaryDrafts = useCallback(
    (
      updater:
        | Record<string, DeliveryProofDraft>
        | ((prev: Record<string, DeliveryProofDraft>) => Record<string, DeliveryProofDraft>),
    ) => {
      setBeneficiaryDraftsState((prev) => {
        const next = typeof updater === "function" ? updater(prev) : updater;
        beneficiaryDraftsRef.current = next;
        return next;
      });
    },
    [],
  );

  const handleBeneficiaryFileAccepted = useCallback(
    (beneficiaryId: string, file: File, kind: ProofImageKind) => {
      setBeneficiaryDrafts((prev) => {
        const previous = prev[beneficiaryId];
        if (previous) URL.revokeObjectURL(previous.previewUrl);
        return {
          ...prev,
          [beneficiaryId]: {
            dealId: operationId,
            file,
            kind,
            previewUrl: URL.createObjectURL(file),
            caption: previous?.caption ?? "",
          },
        };
      });
      setBanner(null);
    },
    [operationId, setBeneficiaryDrafts],
  );

  const clearBeneficiaryDraft = useCallback(
    (beneficiaryId: string) => {
      setBeneficiaryDrafts((prev) => {
        const existing = prev[beneficiaryId];
        if (!existing) return prev;
        URL.revokeObjectURL(existing.previewUrl);
        const next = { ...prev };
        delete next[beneficiaryId];
        return next;
      });
    },
    [setBeneficiaryDrafts],
  );

  const handleBeneficiaryCaptionChange = useCallback(
    (beneficiaryId: string, caption: string) => {
      setBeneficiaryDrafts((prev) => {
        const existing = prev[beneficiaryId];
        if (!existing) return prev;
        return { ...prev, [beneficiaryId]: { ...existing, caption } };
      });
    },
    [setBeneficiaryDrafts],
  );

  const clearAllBeneficiaryDrafts = useCallback(() => {
    setBeneficiaryDrafts((prev) => {
      for (const d of Object.values(prev)) URL.revokeObjectURL(d.previewUrl);
      return {};
    });
  }, [setBeneficiaryDrafts]);

  const handleCancel = useCallback(() => {
    clearDraft();
    clearAllBeneficiaryDrafts();
    setBanner(null);
    setSkipChecked(false);
    onCancel();
  }, [clearDraft, clearAllBeneficiaryDrafts, onCancel]);

  const buildDeps = useCallback(
    (): DeliveryDeps => ({
      canSend: () => canSend,
      isWindowOpen: async (convId) => {
        if (!convId) return false;
        const supabase = createClient();
        const at = await fetchLastCustomerMessageAt(supabase, convId);
        return !sessionWindowFrom(at).expired;
      },
      uploadProof: (file, uploadName) =>
        uploadAccountMedia(
          CHAT_MEDIA_BUCKET,
          new File([file], uploadName, { type: file.type }),
        ),
      sendProof: sendProofImage,
      readStage: async (dealId) => {
        try {
          const response = await fetch(
            `/api/remittance-operations?conversationId=${conversationId}`,
            { cache: "no-store" },
          );
          if (!response.ok) return null;
          const data = (await response.json()) as ConversationOperationsRead;
          const found = data.operations.find((op) => op.id === dealId);
          if (!found) return null;
          return found.status === "ready_to_transfer" ? DELIVERY_PROOF_STAGE_ID : found.status;
        } catch {
          return null;
        }
      },
      discardUpload: async (path) => {
        await deleteAccountMedia(CHAT_MEDIA_BUCKET, path);
      },
      moveToDelivered: async (_id, evidence) => {
        const result = await deliverOperation(operationId, evidenceToRpc(evidence));
        return result.ok ? { ok: true } : { ok: false, message: result.error };
      },
    }),
    [canSend, conversationId, operationId],
  );

  const handleResult = useCallback(
    (result: DeliveryResult) => {
      switch (result.status) {
        case "delivered":
          clearDraft();
          setBanner(null);
          toast.success(t("delivered"));
          onDone();
          return;

        case "window-closed":
          setBanner({
            kind: "warning",
            text: t("windowClosed"),
            action: { label: t("completeAnyway"), onClick: () => void run({ skip: true }) },
          });
          return;

        case "stage-failed":
          if (result.proofSent) {
            setDraft((prev) => (prev ? { ...prev, sentWamid: result.wamid } : prev));
          }
          setBanner({
            kind: "error",
            text: t("stageFailed"),
            action: {
              label: t("retry"),
              onClick: () => void run({ skip: result.proofSent ? false : lastSkipRef.current }),
            },
          });
          return;

        case "sent-not-recorded":
          setDraft((prev) => (prev ? { ...prev, sentWamid: result.wamid } : prev));
          setBanner({
            kind: "error",
            text: t("stageFailed"),
            action: { label: t("retry"), onClick: () => void run({ skip: false }) },
          });
          return;

        case "unconfirmed":
          setBanner({ kind: "error", text: t("unconfirmed") });
          return;

        case "stale-stage":
          setBanner({ kind: "error", text: t("stale") });
          return;

        case "failed":
          setBanner({ kind: "error", text: t("failed", { message: result.message }) });
          return;

        case "blocked":
          setBanner({ kind: "error", text: t("blocked") });
          return;

        case "busy":
          return;
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [clearDraft, onDone, t],
  );

  const run = useCallback(
    async (opts: { skip: boolean }) => {
      // Read from the refs, not the `draft`/`busy` state captured by this
      // closure: the retry/complete-anyway actions are created inside
      // `handleResult`, from whatever render was active when a PREVIOUS
      // attempt resolved, and must still see the draft this render just
      // stamped a `sentWamid` onto.
      if (busyRef.current) return;
      lastSkipRef.current = opts.skip;
      busyRef.current = true;
      setBusy(true);
      const deps = buildDeps();
      try {
        const currentDraft = draftRef.current;
        const result = await deliverDeal(
          {
            dealId: operationId,
            conversationId,
            draft: opts.skip ? null : currentDraft,
            skipProof: opts.skip,
            expectsProof: !!currentDraft && !opts.skip,
          },
          deps,
        );
        handleResult(result);
      } finally {
        busyRef.current = false;
        setBusy(false);
      }
    },
    [buildDeps, operationId, conversationId, handleResult],
  );

  // ---------------------------------------------------------------
  // 2+ beneficiaries: send + record each proof, then run `deliverDeal`
  // ONCE more, exactly as the single-proof path above — with a synthetic
  // draft carrying the LAST beneficiary's `sentWamid`/`sentPath`, so it
  // takes `deliverDeal`'s existing "already sent" branch straight to the
  // stage update rather than uploading/sending anything itself (panel
  // contract, P2's doc). Only ever called when `skipChecked` is false —
  // skipping bypasses every beneficiary's proof at once and reuses `run`
  // directly (see `onSubmit` below), the same "complete without
  // screenshot" escape hatch the single-beneficiary path has always had.
  // ---------------------------------------------------------------

  const buildBeneficiaryDeps = useCallback(
    (): BeneficiaryProofDeps => ({
      conversationId,
      uploadProof: (file, uploadName) =>
        uploadAccountMedia(
          CHAT_MEDIA_BUCKET,
          new File([file], uploadName, { type: file.type }),
        ),
      sendProof: sendProofImage,
      discardUpload: async (path) => {
        await deleteAccountMedia(CHAT_MEDIA_BUCKET, path);
      },
      registerProof: async (beneficiaryId, evidence) => {
        const result = await registerBeneficiaryProof(operationId, beneficiaryId, evidence);
        return result.ok
          ? { ok: true, missing: result.missing }
          : { ok: false, message: result.error };
      },
    }),
    [conversationId, operationId],
  );

  const handleMultiDeliverResult = useCallback(
    (result: DeliveryResult) => {
      switch (result.status) {
        case "delivered":
          clearAllBeneficiaryDrafts();
          setBanner(null);
          toast.success(t("delivered"));
          onDone();
          return;

        case "stage-failed":
          // Every beneficiary is already sent and recorded at this point
          // (this call only runs after `sendBeneficiaryProofs` reports
          // "sent") — retrying re-enters `runMulti`, which skips the
          // whole send/register loop (every draft already carries its
          // `sentWamid`) and goes straight back to this same call.
          setBanner({
            kind: "error",
            text: t("stageFailed"),
            action: { label: t("retry"), onClick: () => void runMulti() },
          });
          return;

        case "busy":
          return;

        default:
          // Unreachable in practice: a draft carrying `sentWamid` takes
          // `deliverDeal`'s "already sent" branch, which only ever
          // returns "delivered" or "stage-failed". Kept exhaustive for
          // type safety and defense in depth.
          setBanner({ kind: "error", text: t("blocked") });
          return;
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [clearAllBeneficiaryDrafts, onDone, t],
  );

  const runMulti = useCallback(async () => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      const currentDrafts = beneficiaryDraftsRef.current;
      const missing = beneficiaries.some((b) => !currentDrafts[b.id]);
      if (missing) {
        setBanner({ kind: "error", text: t("missingProofs") });
        return;
      }

      const items: BeneficiaryProofItem[] = beneficiaries.map((b) => {
        const d = currentDrafts[b.id]!;
        return {
          beneficiaryId: b.id,
          file: d.file,
          kind: d.kind,
          caption: d.caption,
          sentWamid: d.sentWamid,
          sentPath: d.sentPath,
        };
      });

      const sendResult = await sendBeneficiaryProofs(items, buildBeneficiaryDeps());

      // Persist progress either way — a partial failure must keep every
      // already-sent wamid/path so a retry does not re-send that image.
      setBeneficiaryDrafts((prev) => {
        const next = { ...prev };
        for (const sentItem of sendResult.items) {
          const existing = next[sentItem.beneficiaryId];
          if (existing) {
            next[sentItem.beneficiaryId] = {
              ...existing,
              sentWamid: sentItem.sentWamid,
              sentPath: sentItem.sentPath,
            };
          }
        }
        return next;
      });

      if (sendResult.status === "failed") {
        setBanner({
          kind: "error",
          text: t("failed", { message: sendResult.message }),
          action: { label: t("retry"), onClick: () => void runMulti() },
        });
        return;
      }

      const last = sendResult.items[sendResult.items.length - 1]!;
      const finalDraft: DeliveryProofDraft = {
        dealId: operationId,
        file: last.file,
        kind: last.kind,
        previewUrl: "",
        caption: last.caption,
        sentWamid: last.sentWamid,
        sentPath: last.sentPath,
      };
      const result = await deliverDeal(
        {
          dealId: operationId,
          conversationId,
          draft: finalDraft,
          skipProof: false,
          expectsProof: true,
        },
        buildDeps(),
      );
      handleMultiDeliverResult(result);
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [beneficiaries, buildBeneficiaryDeps, buildDeps, operationId, conversationId, handleMultiDeliverResult, t]);

  if (multiMode) {
    const items: CompleteTransferProofItem[] = beneficiaries.map((b, index) => {
      const d = beneficiaryDrafts[b.id];
      return {
        beneficiaryId: b.id,
        label: t("beneficiaryLabel", { n: index + 1 }),
        showCaption: b.isZelle,
        file: d?.file ?? null,
        previewUrl: d?.previewUrl ?? null,
        caption: d?.caption ?? "",
        onFileAccepted: (file, kind) => handleBeneficiaryFileAccepted(b.id, file, kind),
        onFileRejected: handleFileRejected,
        onCaptionChange: (caption) => handleBeneficiaryCaptionChange(b.id, caption),
        onClear: () => clearBeneficiaryDraft(b.id),
      };
    });
    const canSubmit = skipChecked || beneficiaries.every((b) => !!beneficiaryDrafts[b.id]);

    return (
      <CompleteTransferMultiSection
        items={items}
        skipChecked={skipChecked}
        onSkipChange={setSkipChecked}
        busy={busy}
        canSend={canSend}
        canSubmit={canSubmit}
        banner={banner}
        onCancel={handleCancel}
        onSubmit={() => void (skipChecked ? run({ skip: true }) : runMulti())}
      />
    );
  }

  return (
    <CompleteTransferSection
      showCaption={isZelle}
      file={draft?.file ?? null}
      previewUrl={draft?.previewUrl ?? null}
      caption={draft?.caption ?? ""}
      onFileAccepted={handleFileAccepted}
      onFileRejected={handleFileRejected}
      onCaptionChange={handleCaptionChange}
      onClear={clearDraft}
      skipChecked={skipChecked}
      onSkipChange={setSkipChecked}
      busy={busy}
      canSend={canSend}
      banner={banner}
      onCancel={handleCancel}
      onSubmit={() => void run({ skip: skipChecked })}
    />
  );
}
