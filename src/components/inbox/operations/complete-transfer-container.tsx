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
import { DELIVERY_PROOF_STAGE_ID } from "@/lib/pipelines/delivery-stages";
import { deliverOperation } from "@/lib/remittance-operations/commands";
import { evidenceToRpc } from "@/lib/remittance-operations/delivery";
import type { ConversationOperationsRead } from "@/lib/remittance-operations/types";
import { CompleteTransferSection, type CompleteTransferBanner } from "./complete-transfer-section";

export interface CompleteTransferContainerProps {
  operationId: string;
  conversationId: string;
  /** Only Zelle transfers show the note field (the recipient's name never
   *  appears anywhere else once the screenshot is sent). */
  isZelle: boolean;
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
  onDone,
  onCancel,
}: CompleteTransferContainerProps) {
  const t = useTranslations("Inbox.operationsPanel.completeTransfer");
  const canSend = useCan("send-messages");
  const [draft, setDraftState] = useState<DeliveryProofDraft | null>(null);
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
  useEffect(() => {
    function handleDocumentPaste(event: ClipboardEvent) {
      if (event.defaultPrevented) return;
      const image = pickPastedImage(event.clipboardData as unknown as ClipboardLike);
      if (!image) return;
      event.preventDefault();
      void acceptPastedImage(image);
    }

    document.addEventListener("paste", handleDocumentPaste);
    return () => document.removeEventListener("paste", handleDocumentPaste);
  }, [acceptPastedImage]);

  const handleCaptionChange = useCallback(
    (caption: string) => {
      setDraft((prev) => (prev ? { ...prev, caption } : prev));
    },
    [setDraft],
  );

  const handleCancel = useCallback(() => {
    clearDraft();
    setBanner(null);
    setSkipChecked(false);
    onCancel();
  }, [clearDraft, onCancel]);

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
