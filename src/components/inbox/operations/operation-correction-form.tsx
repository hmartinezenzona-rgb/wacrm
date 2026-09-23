"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { corregirOperacion } from "@/lib/remittance-operations/commands";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

interface OperationCorrectionFormProps {
  operation: RemittanceOperationRead;
  onDone: () => void;
  onCancel: () => void;
}

const CURRENCY_PATTERN = /^[A-Z]{3}$/;

/**
 * Inline correction form for an operation's admin-owned fields
 * (destination currency, delivery/deposit method, quoted amounts). Sends
 * only the fields the agent actually changed, snake_case, amounts as
 * numbers — mirrors `corregirOperacion`'s `cambios` contract exactly.
 */
export function OperationCorrectionForm({ operation, onDone, onCancel }: OperationCorrectionFormProps) {
  const t = useTranslations("Inbox.operationsPanel");

  const initialDestinationCurrency = operation.destinationCurrency ?? "";
  const initialDeliveryMethod = operation.deliveryMethod ?? "";
  const initialDepositMethod = operation.depositMethod ?? "";
  const initialQuotedSourceAmount =
    operation.quotedSourceAmount === null ? "" : String(operation.quotedSourceAmount);
  const initialQuotedDestinationAmount =
    operation.quotedDestinationAmount === null ? "" : String(operation.quotedDestinationAmount);

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

    if (Object.keys(changes).length === 0) {
      setError(t("noChanges"));
      return;
    }

    setPending(true);
    const result = await corregirOperacion(operation.id, changes);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }

    onDone();
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-2 rounded-md border border-border bg-muted/40 p-2">
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
        <Button type="button" variant="outline" size="sm" onClick={onCancel} disabled={pending}>
          {t("cancel")}
        </Button>
        <Button type="submit" size="sm" disabled={pending}>
          {t("save")}
        </Button>
      </div>
    </form>
  );
}
