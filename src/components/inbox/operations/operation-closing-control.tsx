"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Check, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cerrarOperacionManual, eliminarOperacion } from "@/lib/remittance-operations/commands";
import { NotifyToggle } from "./notify-toggle";

interface OperationClosingControlProps {
  operationId: string;
  /** `close` completes a verified remesa (customer messaged only if the
   *  bell is on); `delete` soft-deletes it. Neither asks for a reason. */
  kind: "close" | "delete";
  onDone: () => void;
  onCancel: () => void;
}

/**
 * Inline confirmation for the owner/admin closing actions (migrations
 * 190/191): a short warning and icon-only buttons (green check confirms, X
 * cancels). Closing also shows the notify-customer bell, off by default.
 * The server re-checks role and status, so a refusal (e.g. a remesa holding
 * a consumed deposit) surfaces here as its message.
 */
export function OperationClosingControl({ operationId, kind, onDone, onCancel }: OperationClosingControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [notify, setNotify] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isClose = kind === "close";
  const confirmLabel = isClose ? t("closing.closeConfirm") : t("closing.deleteConfirm");

  async function handleConfirm() {
    setError(null);
    setPending(true);
    const result = isClose
      ? await cerrarOperacionManual(operationId, notify)
      : await eliminarOperacion(operationId);
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

      {error && <p className="text-xs text-destructive">{error}</p>}

      <div className="flex items-center justify-end gap-1">
        {isClose && <NotifyToggle notify={notify} onChange={setNotify} disabled={pending} />}
        <Button
          type="button"
          variant="outline"
          size="icon-sm"
          aria-label={t("cancel")}
          title={t("cancel")}
          onClick={onCancel}
          disabled={pending}
        >
          <X aria-hidden="true" />
        </Button>
        <Button
          type="button"
          size="icon-sm"
          aria-label={confirmLabel}
          title={confirmLabel}
          className="bg-green-600 text-white hover:bg-green-700"
          disabled={pending}
          onClick={handleConfirm}
        >
          <Check aria-hidden="true" />
        </Button>
      </div>
    </div>
  );
}
