"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { corregirBeneficiario } from "@/lib/remittance-operations/commands";
import type { BeneficiaryType, RemittanceBeneficiaryRead } from "@/lib/remittance-operations/types";

interface BeneficiaryCorrectionFormProps {
  beneficiary: RemittanceBeneficiaryRead;
  onDone: () => void;
  onCancel: () => void;
}

const CURRENCY_PATTERN = /^[A-Z]{3}$/;
const CARD_NUMBER_PATTERN = /^\d{16}$/;
const PHONE_PATTERN = /^\d{8,15}$/;

const BENEFICIARY_TYPES: BeneficiaryType[] = [
  "cuban_card",
  "zelle",
  "clasica",
  "tropical",
  "multiple_distribution",
];

/**
 * Inline correction form for one beneficiary. `cardNumber`/`phone` never
 * re-display the raw value (the read model only ever gives us the masked
 * form) — they start empty, with the masked value as a placeholder, and
 * are only sent when the agent actually types a new one. Every other
 * field is prefilled and only sent when non-empty and changed.
 */
export function BeneficiaryCorrectionForm({ beneficiary, onDone, onCancel }: BeneficiaryCorrectionFormProps) {
  const t = useTranslations("Inbox.operationsPanel");

  const initialName = beneficiary.name ?? "";
  const initialZelleAccount = beneficiary.zelleAccount ?? "";
  const initialDeliveryMethod = beneficiary.deliveryMethod ?? "";
  const initialAmount = beneficiary.amount === null ? "" : String(beneficiary.amount);
  const initialCurrency = beneficiary.currency ?? "";
  const initialBeneficiaryType = beneficiary.beneficiaryType;

  const [name, setName] = useState(initialName);
  const [cardNumber, setCardNumber] = useState("");
  const [phone, setPhone] = useState("");
  const [zelleAccount, setZelleAccount] = useState(initialZelleAccount);
  const [deliveryMethod, setDeliveryMethod] = useState(initialDeliveryMethod);
  const [amount, setAmount] = useState(initialAmount);
  const [currency, setCurrency] = useState(initialCurrency);
  const [beneficiaryType, setBeneficiaryType] = useState<BeneficiaryType>(initialBeneficiaryType);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);

    const changes: Record<string, unknown> = {};

    if (name !== initialName && name.trim() !== "") {
      changes.name = name.trim();
    }

    if (cardNumber.trim() !== "") {
      if (!CARD_NUMBER_PATTERN.test(cardNumber.trim())) {
        setError(t("invalidCard"));
        return;
      }
      changes.card_number = cardNumber.trim();
    }

    if (phone.trim() !== "") {
      if (!PHONE_PATTERN.test(phone.trim())) {
        setError(t("invalidPhone"));
        return;
      }
      changes.phone = phone.trim();
    }

    if (zelleAccount !== initialZelleAccount && zelleAccount.trim() !== "") {
      changes.zelle_account = zelleAccount.trim();
    }

    if (deliveryMethod !== initialDeliveryMethod && deliveryMethod.trim() !== "") {
      changes.delivery_method = deliveryMethod.trim();
    }

    if (amount !== initialAmount && amount.trim() !== "") {
      const parsed = Number(amount);
      if (!(parsed > 0)) {
        setError(t("invalidAmount"));
        return;
      }
      changes.amount = parsed;
    }

    if (currency !== initialCurrency && currency.trim() !== "") {
      if (!CURRENCY_PATTERN.test(currency)) {
        setError(t("invalidCurrency"));
        return;
      }
      changes.currency = currency;
    }

    if (beneficiaryType !== initialBeneficiaryType) {
      changes.beneficiary_type = beneficiaryType;
    }

    if (Object.keys(changes).length === 0) {
      setError(t("noChanges"));
      return;
    }

    setPending(true);
    const result = await corregirBeneficiario(beneficiary.id, changes);
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
        <Label htmlFor="beneficiary-name">{t("name")}</Label>
        <Input id="beneficiary-name" value={name} onChange={(event) => setName(event.target.value)} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="beneficiary-card-number">{t("cardNumber")}</Label>
        <Input
          id="beneficiary-card-number"
          value={cardNumber}
          placeholder={beneficiary.cardNumberMasked ?? undefined}
          onChange={(event) => setCardNumber(event.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="beneficiary-phone">{t("phone")}</Label>
        <Input
          id="beneficiary-phone"
          value={phone}
          placeholder={beneficiary.phoneMasked ?? undefined}
          onChange={(event) => setPhone(event.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="beneficiary-zelle-account">{t("zelleAccount")}</Label>
        <Input
          id="beneficiary-zelle-account"
          value={zelleAccount}
          onChange={(event) => setZelleAccount(event.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="beneficiary-delivery-method">{t("deliveryMethod")}</Label>
        <Input
          id="beneficiary-delivery-method"
          value={deliveryMethod}
          onChange={(event) => setDeliveryMethod(event.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="beneficiary-amount">{t("amount")}</Label>
        <Input id="beneficiary-amount" value={amount} onChange={(event) => setAmount(event.target.value)} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="beneficiary-currency">{t("currency")}</Label>
        <Input id="beneficiary-currency" value={currency} onChange={(event) => setCurrency(event.target.value)} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="beneficiary-type">{t("beneficiaryTypeField")}</Label>
        <select
          id="beneficiary-type"
          value={beneficiaryType}
          onChange={(event) => setBeneficiaryType(event.target.value as BeneficiaryType)}
          className="h-8 w-full rounded-lg border border-input bg-transparent px-2.5 text-sm outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
        >
          {BENEFICIARY_TYPES.map((type) => (
            <option key={type} value={type}>
              {t(`beneficiaryType.${type}`)}
            </option>
          ))}
        </select>
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
