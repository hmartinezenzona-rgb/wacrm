"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, FieldRow, UNDERLINE_SELECT_TRIGGER } from "./edit-form-fields";
import { NotifyToggle } from "./notify-toggle";
import { cambiarEstado } from "@/lib/remittance-operations/commands";

/** The states an open operation can be moved to from the panel (migration 379), in the order of its life. */
const STATES = ["collecting_information", "awaiting_deposit", "deposit_verification", "ready_to_transfer"] as const;

interface OperationStatusControlProps {
  operationId: string;
  currentStatus: string;
  onDone: () => void;
  onCancel: () => void;
}

/**
 * Inline control to move an open operation to another open state, forward or back (a wrong verification can be taken back, an operation
 * created from scratch can be put in verification so that it can be verified). Completing and cancelling keep their own actions. The bell
 * only appears for ready_to_transfer: it decides whether the customer gets the verified notice (off by default). The server re-checks role
 * and state, so a refusal surfaces here as its message.
 */
export function OperationStatusControl({ operationId, currentStatus, onDone, onCancel }: OperationStatusControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [estado, setEstado] = useState("");
  const [notify, setNotify] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (estado === "") return;
    setError(null);
    setPending(true);
    const result = await cambiarEstado(operationId, estado, estado === "ready_to_transfer" && notify);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }
    onDone();
  }

  return (
    <form onSubmit={handleSubmit} onKeyDown={cancelOnEscape(onCancel)} className={EDIT_AREA}>
      <FieldRow label={t("changeStatus")} htmlFor="operation-new-status">
        <Select id="operation-new-status" value={estado} disabled={pending} onValueChange={(value) => setEstado(value ?? "")}>
          <SelectTrigger className={UNDERLINE_SELECT_TRIGGER}>
            {/* Base UI paints the raw value unless it is given the label. */}
            <SelectValue placeholder={t("changeStatus")}>
              {(value) => (value ? t(`status.${value as string}`) : t("changeStatus"))}
            </SelectValue>
          </SelectTrigger>
          <SelectContent>
            {STATES.filter((state) => state !== currentStatus).map((state) => (
              <SelectItem key={state} value={state}>
                {t(`status.${state}`)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </FieldRow>
      <div className="flex items-center gap-2">
        {error && <p className="min-w-0 flex-1 text-xs text-destructive">{error}</p>}
        <ConfirmCancelButtons
          type="submit"
          onCancel={onCancel}
          confirmLabel={t("confirmChangeStatus")}
          pending={pending}
          confirmDisabled={estado === ""}
        >
          {estado === "ready_to_transfer" && <NotifyToggle notify={notify} onChange={setNotify} disabled={pending} />}
        </ConfirmCancelButtons>
      </div>
    </form>
  );
}
