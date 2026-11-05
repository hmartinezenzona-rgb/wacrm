"use client";

import { useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { cerrarOperacionManual } from "@/lib/remittance-operations/commands";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { NotifyToggle } from "./notify-toggle";

interface MixedCloseControlProps {
  /** The group's open members, in the order they are closed. */
  operationIds: string[];
  /** Every member was closed. */
  onDone: () => void;
  onCancel: () => void;
}

/**
 * "Cerrar manualmente" for a whole mixed send: the same inline confirmation as a card's (icon buttons,
 * bell off by default), and the existing per-operation manual close once per member, in order. It stops at the first
 * member the server refuses and shows its reason; members already closed are not sent again on the next try.
 */
export function MixedCloseControl({ operationIds, onDone, onCancel }: MixedCloseControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const tGroup = useTranslations("Inbox.operationsPanel.mixedSend");
  const [notify, setNotify] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [doneCount, setDoneCount] = useState(0);
  const closed = useRef<Set<string>>(new Set());

  async function handleConfirm() {
    setError(null);
    setPending(true);
    try {
      for (const id of operationIds) {
        if (closed.current.has(id)) continue;
        const result = await cerrarOperacionManual(id, notify);
        if (!result.ok) {
          setError(result.error);
          return;
        }
        closed.current.add(id);
        setDoneCount(closed.current.size);
      }
      onDone();
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="space-y-1 border-l-2 border-border pl-2" onKeyDown={pending ? undefined : cancelOnEscape(onCancel)}>
      {error && <p className="text-xs text-destructive">{error}</p>}
      {doneCount > 0 && (
        <p className="text-xs text-muted-foreground">{tGroup("closeProgress", { done: doneCount, total: operationIds.length })}</p>
      )}
      <ConfirmCancelButtons onCancel={onCancel} onConfirm={handleConfirm} confirmLabel={tGroup("closeConfirm")} cancelLabel={t("cancel")} pending={pending}>
        <NotifyToggle notify={notify} onChange={setNotify} disabled={pending} />
      </ConfirmCancelButtons>
    </div>
  );
}
