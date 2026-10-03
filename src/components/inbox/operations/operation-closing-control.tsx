"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { cerrarOperacionManual, eliminarOperacion } from "@/lib/remittance-operations/commands";

interface OperationClosingControlProps {
  operationId: string;
  /** `close` completes a verified remesa without notifying the customer;
   *  `delete` soft-deletes it. Both need a reason. */
  kind: "close" | "delete";
  onDone: () => void;
  onCancel: () => void;
}

const MAX_REASON_LENGTH = 500;

/**
 * Inline confirmation for the owner/admin closing actions (migration 190):
 * states what will happen, asks for the required reason, then calls the
 * matching command. The server re-checks role and status, so a refusal
 * (e.g. a remesa holding a consumed deposit) surfaces here as its message.
 */
export function OperationClosingControl({ operationId, kind, onDone, onCancel }: OperationClosingControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [reason, setReason] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isClose = kind === "close";
  const trimmedReason = reason.trim();

  async function handleConfirm() {
    setError(null);
    setPending(true);
    const result = isClose
      ? await cerrarOperacionManual(operationId, trimmedReason)
      : await eliminarOperacion(operationId, trimmedReason);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }
    onDone();
  }

  return (
    <div className="space-y-1.5 rounded-md border border-border bg-muted/40 p-2">
      <p className="text-xs text-muted-foreground">
        {isClose ? t("closing.closeWarning") : t("closing.deleteWarning")}
      </p>
      <div className="space-y-1">
        <Label htmlFor={`closing-reason-${operationId}`}>{t("closing.reasonLabel")}</Label>
        <Textarea
          id={`closing-reason-${operationId}`}
          value={reason}
          maxLength={MAX_REASON_LENGTH}
          onChange={(event) => setReason(event.target.value)}
        />
      </div>

      {error && <p className="text-xs text-destructive">{error}</p>}

      <div className="flex justify-end gap-2">
        <Button type="button" variant="outline" size="sm" onClick={onCancel} disabled={pending}>
          {t("cancel")}
        </Button>
        <Button
          type="button"
          size="sm"
          variant={isClose ? "default" : "destructive"}
          disabled={pending || trimmedReason === ""}
          onClick={handleConfirm}
        >
          {isClose
            ? pending ? t("closing.closing") : t("closing.closeConfirm")
            : pending ? t("closing.deleting") : t("closing.deleteConfirm")}
        </Button>
      </div>
    </div>
  );
}
