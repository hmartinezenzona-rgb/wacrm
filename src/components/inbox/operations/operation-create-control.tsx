"use client";

import { useState, type FormEvent } from "react";
import { Plus } from "lucide-react";
import { useTranslations } from "next-intl";
import { useServiceName } from "@/hooks/use-service-name";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, FieldRow, UNDERLINE_SELECT_TRIGGER, UnderlineInput } from "./edit-form-fields";
import { crearOperacion } from "@/lib/remittance-operations/commands";
import { OPERATION_SERVICES } from "@/lib/remittance-operations/services";

interface OperationCreateControlProps {
  conversationId: string;
  /** Called with the new operation's id, so the panel refreshes and opens it. */
  onCreated: (operationId: string) => void;
}

/**
 * "New operation" for the open conversation (migration 378): a button that opens an inline form with the service and the deposit in
 * GYD. The operation starts open; its recipients, deposit and closing use the card's own controls. A combo may start with no amount
 * (its total is the sum of its recipients); every other service needs an amount greater than 0. The server re-checks role and values.
 */
export function OperationCreateControl({ conversationId, onCreated }: OperationCreateControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const serviceName = useServiceName();
  const [open, setOpen] = useState(false);
  const [service, setService] = useState("");
  const [amount, setAmount] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function close() {
    setOpen(false);
    setService("");
    setAmount("");
    setError(null);
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (service === "") return;
    setError(null);

    const typed = amount.replace(/[,\s]/g, "");
    let monto: number | null = null;
    if (typed !== "") {
      monto = Number(typed);
      if (!Number.isFinite(monto) || monto <= 0) {
        setError(t("invalidAmount"));
        return;
      }
    } else if (service !== "combo") {
      setError(t("invalidAmount"));
      return;
    }

    setPending(true);
    const result = await crearOperacion(conversationId, service, monto);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }
    close();
    onCreated(result.id);
  }

  if (!open) {
    return (
      <Button
        type="button"
        variant="ghost"
        size="icon-xs"
        aria-label={t("newOperation")}
        title={t("newOperation")}
        onClick={() => setOpen(true)}
      >
        <Plus aria-hidden="true" />
      </Button>
    );
  }

  return (
    <form onSubmit={handleSubmit} onKeyDown={cancelOnEscape(close)} className={`${EDIT_AREA} w-full`}>
      <FieldRow label={t("serviceChange.label")} htmlFor="new-operation-service">
        <Select id="new-operation-service" value={service} disabled={pending} onValueChange={(value) => setService(value ?? "")}>
          <SelectTrigger className={UNDERLINE_SELECT_TRIGGER}>
            {/* Base UI paints the raw value unless it is given the label. */}
            <SelectValue placeholder={t("serviceChange.choose")}>
              {(value) => (value ? serviceName(value as string) : t("serviceChange.choose"))}
            </SelectValue>
          </SelectTrigger>
          <SelectContent>
            {OPERATION_SERVICES.map((option) => (
              <SelectItem key={option} value={option}>
                {serviceName(option)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </FieldRow>
      <FieldRow label={t("quotedSourceAmount")} htmlFor="new-operation-amount">
        <UnderlineInput
          id="new-operation-amount"
          inputMode="decimal"
          value={amount}
          placeholder={service === "combo" ? t("optionalAmount") : undefined}
          disabled={pending}
          onChange={(event) => setAmount(event.target.value)}
        />
      </FieldRow>
      <div className="flex items-center gap-2">
        {error && <p className="min-w-0 flex-1 text-xs text-destructive">{error}</p>}
        <ConfirmCancelButtons
          type="submit"
          onCancel={close}
          confirmLabel={t("confirmNewOperation")}
          pending={pending}
          confirmDisabled={service === ""}
        />
      </div>
    </form>
  );
}
