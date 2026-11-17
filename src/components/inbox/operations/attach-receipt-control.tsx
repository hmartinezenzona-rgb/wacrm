"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { IdPhotoPicker } from "./id-photo-picker";
import { adjuntarComprobante } from "@/lib/remittance-operations/commands";

interface AttachReceiptControlProps {
  operationId: string;
  conversationId: string;
  /** The receipt was attached: the panel reloads the receipts. */
  onAttached: () => void;
  /** Whether the operation is in a state where the verify form exists. When
   *  it is not, the note tells the person to move the operation to deposit
   *  verification instead of pointing at a form that isn't there. */
  verifyAvailable?: boolean;
}

/**
 * "Attach a receipt from the chat" (migration 382): the chat-image picker the cash ID photo already uses. Choosing an image stores it as a
 * receipt of the operation, with the reference and the amount of the system's own reading of that image when there is one. It verifies
 * nothing: the person types or checks the reference and the amount and uses the verify of the deposit block. The server re-checks role, the
 * state of the operation and that the image belongs to its conversation.
 */
export function AttachReceiptControl({ operationId, conversationId, onAttached, verifyAvailable = true }: AttachReceiptControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [pending, setPending] = useState(false);
  const [note, setNote] = useState<{ kind: "ok" | "error"; text: string } | null>(null);

  async function handlePick(wamid: string) {
    setNote(null);
    setPending(true);
    const result = await adjuntarComprobante(operationId, wamid);
    setPending(false);

    if (!result.ok) {
      setNote({
        kind: "error",
        text: result.error === "receipt_already_attached" ? t("attachReceipt.alreadyAttached") : result.error,
      });
      return;
    }
    setNote({
      kind: "ok",
      text: verifyAvailable
        ? result.prefilled
          ? t("attachReceipt.attachedPrefilled")
          : t("attachReceipt.attached")
        : t("attachReceipt.attachedNeedsStage"),
    });
    onAttached();
  }

  return (
    <div className="space-y-1">
      <IdPhotoPicker
        conversationId={conversationId}
        selectedWamid={null}
        label={t("attachReceipt.label")}
        disabled={pending}
        onPick={handlePick}
      />
      {note && <p className={`text-xs ${note.kind === "error" ? "text-destructive" : "text-muted-foreground"}`}>{note.text}</p>}
    </div>
  );
}
