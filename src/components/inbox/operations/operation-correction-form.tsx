"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Check, X } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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
    <form onSubmit={handleSubmit} className="space-y-2 rounded-md border border-border bg-muted/40 p-2">
      <div className="space-y-1">
        <Label htmlFor="operation-service">{t("serviceChange.label")}</Label>
        <select
          id="operation-service"
          value={service}
          disabled={pending}
          onChange={(event) => setService(event.target.value)}
          className="h-8 w-full min-w-0 rounded-lg border border-input bg-transparent px-2.5 py-1 text-base outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-50 md:text-sm dark:bg-input/30"
        >
          {initialService === "" && (
            <option value="" disabled>
              {t("serviceChange.choose")}
            </option>
          )}
          {OPERATION_SERVICES.map((option) => (
            <option key={option} value={option}>
              {t(`closing.method.${option}`)}
            </option>
          ))}
        </select>
        {service !== "" && service !== initialService && (
          <p className="text-xs text-muted-foreground">{t("serviceChange.warning")}</p>
        )}
      </div>
      <div className="space-y-1">
        <Label htmlFor="operation-destination-currency">{t("destinationCurrency")}</Label>
        <Input
          id="operation-destination-currency"
          value={destinationCurrency}
          onChange={(event) => setDestinationCurrency(event.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="operation-delivery-method">{t("deliveryMethod")}</Label>
        <Input
          id="operation-delivery-method"
          value={deliveryMethod}
          onChange={(event) => setDeliveryMethod(event.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="operation-deposit-method">{t("depositMethod")}</Label>
        <Input
          id="operation-deposit-method"
          value={depositMethod}
          onChange={(event) => setDepositMethod(event.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="operation-quoted-source-amount">{t("quotedSourceAmount")}</Label>
        <Input
          id="operation-quoted-source-amount"
          value={quotedSourceAmount}
          onChange={(event) => setQuotedSourceAmount(event.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="operation-quoted-destination-amount">{t("quotedDestinationAmount")}</Label>
        <Input
          id="operation-quoted-destination-amount"
          value={quotedDestinationAmount}
          onChange={(event) => setQuotedDestinationAmount(event.target.value)}
        />
      </div>

      {error && <p className="text-xs text-destructive">{error}</p>}

      <div className="flex justify-end gap-2">
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
          type="submit"
          size="icon-sm"
          aria-label={t("save")}
          title={t("save")}
          className="bg-green-600 text-white hover:bg-green-700"
          disabled={pending}
        >
          <Check aria-hidden="true" />
        </Button>
      </div>
    </form>
  );
}
