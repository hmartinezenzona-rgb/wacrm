"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { toast } from "sonner";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, FieldPair, FieldRow, PairCell, UNDERLINE_SELECT_TRIGGER, UnderlineInput } from "./edit-form-fields";
import { cambiarServicio, corregirOperacion } from "@/lib/remittance-operations/commands";
import { OPERATION_SERVICES, currentServiceOf } from "@/lib/remittance-operations/services";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

interface OperationCorrectionFormProps {
  operation: RemittanceOperationRead;
  onDone: () => void;
  onCancel: () => void;
}

const CURRENCY_PATTERN = /^[A-Z]{3}$/;

/**
 * Inline correction form for an operation's admin-owned fields
 * (service, destination currency, delivery/deposit method, quoted amounts).
 * Sends only the fields the agent actually changed, snake_case, amounts as
 * numbers — mirrors `corregirOperacion`'s `cambios` contract exactly. The
 * service goes through its own command (`cambiarServicio`) and runs first,
 * because it recalculates the quote the other corrections may then adjust.
 * Confirmed with the check, cancelled with the X (as the closing control).
 */
export function OperationCorrectionForm({ operation, onDone, onCancel }: OperationCorrectionFormProps) {
  const t = useTranslations("Inbox.operationsPanel");

  const initialService = currentServiceOf(operation) ?? "";
  const initialDestinationCurrency = operation.destinationCurrency ?? "";
  const initialDeliveryMethod = operation.deliveryMethod ?? "";
  const initialDepositMethod = operation.depositMethod ?? "";
  const initialQuotedSourceAmount =
    operation.quotedSourceAmount === null ? "" : String(operation.quotedSourceAmount);
  const initialQuotedDestinationAmount =
    operation.quotedDestinationAmount === null ? "" : String(operation.quotedDestinationAmount);

  const [service, setService] = useState<string>(initialService);
  const [destinationCurrency, setDestinationCurrency] = useState(initialDestinationCurrency);
  const [deliveryMethod, setDeliveryMethod] = useState(initialDeliveryMethod);
  const [depositMethod, setDepositMethod] = useState(initialDepositMethod);
  const [quotedSourceAmount, setQuotedSourceAmount] = useState(initialQuotedSourceAmount);
  const [quotedDestinationAmount, setQuotedDestinationAmount] = useState(initialQuotedDestinationAmount);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);

    const changes: Record<string, unknown> = {};

    if (destinationCurrency !== initialDestinationCurrency) {
      if (!CURRENCY_PATTERN.test(destinationCurrency)) {
        setError(t("invalidCurrency"));
        return;
      }
      changes.destination_currency = destinationCurrency;
    }

    if (deliveryMethod !== initialDeliveryMethod) {
      changes.delivery_method = deliveryMethod;
    }

    if (depositMethod !== initialDepositMethod) {
      changes.deposit_method = depositMethod;
    }

    if (quotedSourceAmount !== initialQuotedSourceAmount) {
      const amount = Number(quotedSourceAmount);
      if (!(amount > 0)) {
        setError(t("invalidAmount"));
        return;
      }
      changes.quoted_source_amount = amount;
    }

    if (quotedDestinationAmount !== initialQuotedDestinationAmount) {
      const amount = Number(quotedDestinationAmount);
      if (!(amount > 0)) {
        setError(t("invalidAmount"));
        return;
      }
      changes.quoted_destination_amount = amount;
    }

    const serviceChanged = service !== "" && service !== initialService;

    if (!serviceChanged && Object.keys(changes).length === 0) {
      setError(t("noChanges"));
      return;
    }

    setPending(true);

    if (serviceChanged) {
      const changed = await cambiarServicio(operation.id, service);
      if (!changed.ok) {
        setPending(false);
        toast.error(t("serviceChange.failed", { message: changed.error }));
        setService(initialService);
        return;
      }
      toast.success(t("serviceChange.saved"));
    }

    if (Object.keys(changes).length > 0) {
      const result = await corregirOperacion(operation.id, changes);
      if (!result.ok) {
        setPending(false);
        if (serviceChanged) {
          // The service is already saved: report the rest and refresh, so the form reopens on what is stored now.
          toast.error(result.error);
          onDone();
        } else {
          setError(result.error);
        }
        return;
      }
    }

    setPending(false);
    onDone();
  }

  return (
    <form onSubmit={handleSubmit} onKeyDown={cancelOnEscape(onCancel)} className={EDIT_AREA}>
      <FieldRow label={t("serviceChange.label")} htmlFor="operation-service">
        <Select id="operation-service" value={service} disabled={pending} onValueChange={(v) => setService(v ?? "")}>
          <SelectTrigger className={UNDERLINE_SELECT_TRIGGER}>
            {/* Base UI paints the raw value unless it is given the label. */}
            <SelectValue placeholder={t("serviceChange.choose")}>
              {(v) => (v ? t(`closing.method.${v as string}`) : t("serviceChange.choose"))}
            </SelectValue>
          </SelectTrigger>
          <SelectContent>
            {OPERATION_SERVICES.map((option) => (
              <SelectItem key={option} value={option}>
                {t(`closing.method.${option}`)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </FieldRow>
      {service !== "" && service !== initialService && (
        <p className="text-[11px] text-muted-foreground">{t("serviceChange.warning")}</p>
      )}
      <FieldPair>
        <PairCell label={t("quotedSourceAmount")} htmlFor="operation-quoted-source-amount">
          <UnderlineInput
            id="operation-quoted-source-amount"
            value={quotedSourceAmount}
            onChange={(event) => setQuotedSourceAmount(event.target.value)}
          />
        </PairCell>
        <PairCell label={t("quotedDestinationAmount")} htmlFor="operation-quoted-destination-amount">
          <UnderlineInput
            id="operation-quoted-destination-amount"
            value={quotedDestinationAmount}
            onChange={(event) => setQuotedDestinationAmount(event.target.value)}
          />
        </PairCell>
      </FieldPair>
      <FieldRow label={t("destinationCurrency")} htmlFor="operation-destination-currency">
        <UnderlineInput
          id="operation-destination-currency"
          value={destinationCurrency}
          onChange={(event) => setDestinationCurrency(event.target.value)}
        />
      </FieldRow>
      <FieldRow label={t("deliveryMethod")} htmlFor="operation-delivery-method">
        <UnderlineInput
          id="operation-delivery-method"
          value={deliveryMethod}
          onChange={(event) => setDeliveryMethod(event.target.value)}
        />
      </FieldRow>
      <FieldRow label={t("depositMethod")} htmlFor="operation-deposit-method">
        <UnderlineInput
          id="operation-deposit-method"
          value={depositMethod}
          onChange={(event) => setDepositMethod(event.target.value)}
        />
      </FieldRow>

      <div className="flex items-center gap-2">
        {error && <p className="min-w-0 flex-1 text-xs text-destructive">{error}</p>}
        <ConfirmCancelButtons type="submit" onCancel={onCancel} pending={pending} />
      </div>
    </form>
  );
}
