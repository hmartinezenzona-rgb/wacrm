"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { agregarBeneficiario } from "@/lib/remittance-operations/commands";

interface BeneficiaryAddControlProps {
  operationId: string;
  /** `recarga` and `saldo` turn the form into a single Cuban-mobile-number field; `combo`
   *  into a recipient form (name, phone, address, reference, contact phone, amount). */
  serviceType?: string;
  onDone: () => void;
  onCancel: () => void;
}

const CARD_NUMBER_PATTERN = /^\d{16}$/;
const PHONE_PATTERN = /^\d{8,15}$/;
const CURRENCY_PATTERN = /^[A-Z]{3}$/;
const RECHARGE_PHONE_PATTERN = /^[56]\d{7}$/;

/** Types offered by this control. `multiple_distribution` (reparto) is
 *  deliberately excluded — splitting one payment across several
 *  beneficiaries is its own bot-driven flow, not a single hand-added
 *  beneficiary (see the feature doc's "Decisions to confirm"). */
const ADDABLE_BENEFICIARY_TYPES: ReadonlyArray<string> = ["cuban_card", "zelle", "clasica", "tropical"];

/**
 * Inline "Add beneficiary" form for an open remesa: pick a type, fill in
 * its identifying fields (Zelle: name + account; every other type: card +
 * phone), and an amount + currency — mirrors `crm_agregar_beneficiario`'s
 * `datos` contract exactly (snake_case keys, amount as a number). Sends
 * only the fields the selected type needs.
 */
export function BeneficiaryAddControl({ operationId, serviceType, onDone, onCancel }: BeneficiaryAddControlProps) {
  const t = useTranslations("Inbox.operationsPanel");

  const [beneficiaryType, setBeneficiaryType] = useState("cuban_card");
  const [name, setName] = useState("");
  const [zelleAccount, setZelleAccount] = useState("");
  const [cardNumber, setCardNumber] = useState("");
  const [phone, setPhone] = useState("");
  const [amount, setAmount] = useState("");
  const [currency, setCurrency] = useState("");
  const [address, setAddress] = useState("");
  const [reference, setReference] = useState("");
  const [contactPhone, setContactPhone] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isZelle = beneficiaryType === "zelle";
  // A mobile balance takes its one number through the same phone-only form as a recharge (migration 223).
  const isRecharge = serviceType === "recarga" || serviceType === "saldo";
  const isCombo = serviceType === "combo";

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);

    if (isRecharge) {
      const digits = phone.replace(/\D/g, "");
      if (!RECHARGE_PHONE_PATTERN.test(digits)) {
        setError(t("invalidRechargePhone"));
        return;
      }
      setPending(true);
      const result = await agregarBeneficiario(operationId, { beneficiary_type: "recarga", phone: digits });
      setPending(false);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      onDone();
      return;
    }

    if (isCombo) {
      // The 25,000 GYD minimum is only a hint: the bot enforces it, an admin may know better.
      const trimmedName = name.trim();
      const digitsPhone = phone.replace(/\D/g, "");
      if (trimmedName === "") {
        setError(t("cannotBeEmpty"));
        return;
      }
      if (!PHONE_PATTERN.test(digitsPhone)) {
        setError(t("invalidPhone"));
        return;
      }
      const digitsContact = contactPhone.replace(/\D/g, "");
      if (digitsContact !== "" && !PHONE_PATTERN.test(digitsContact)) {
        setError(t("invalidPhone"));
        return;
      }
      const comboAmount = Number(amount);
      if (!(comboAmount > 0)) {
        setError(t("invalidAmount"));
        return;
      }
      const comboDatos: Record<string, unknown> = {
        beneficiary_type: "combo",
        name: trimmedName,
        phone: digitsPhone,
        amount: comboAmount,
        currency: "GYD",
      };
      if (address.trim() !== "") comboDatos.address = address.trim();
      if (reference.trim() !== "") comboDatos.reference = reference.trim();
      if (digitsContact !== "") comboDatos.contact_phone = digitsContact;
      setPending(true);
      const result = await agregarBeneficiario(operationId, comboDatos);
      setPending(false);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      onDone();
      return;
    }

    const datos: Record<string, unknown> = { beneficiary_type: beneficiaryType };

    if (isZelle) {
      const trimmedName = name.trim();
      const trimmedZelleAccount = zelleAccount.trim();
      if (trimmedName === "" || trimmedZelleAccount === "") {
        setError(t("cannotBeEmpty"));
        return;
      }
      datos.name = trimmedName;
      datos.zelle_account = trimmedZelleAccount;
    } else {
      const digitsCard = cardNumber.replace(/\D/g, "");
      if (!CARD_NUMBER_PATTERN.test(digitsCard)) {
        setError(t("invalidCard"));
        return;
      }
      // The phone is optional for a card (migration 190) — validated only
      // when given, and left out of `datos` when empty.
      const digitsPhone = phone.replace(/\D/g, "");
      if (digitsPhone !== "" && !PHONE_PATTERN.test(digitsPhone)) {
        setError(t("invalidPhone"));
        return;
      }
      datos.card_number = digitsCard;
      if (digitsPhone !== "") datos.phone = digitsPhone;
    }

    const parsedAmount = Number(amount);
    if (!(parsedAmount > 0)) {
      setError(t("invalidAmount"));
      return;
    }
    datos.amount = parsedAmount;

    if (!CURRENCY_PATTERN.test(currency)) {
      setError(t("invalidCurrency"));
      return;
    }
    datos.currency = currency;

    setPending(true);
    const result = await agregarBeneficiario(operationId, datos);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }

    onDone();
  }

  if (isRecharge) {
    return (
      <form onSubmit={handleSubmit} className="space-y-2 rounded-md border border-border bg-muted/40 p-2">
        <div className="space-y-1">
          <Label htmlFor="add-beneficiary-phone">{t("phone")}</Label>
          <Input
            id="add-beneficiary-phone"
            inputMode="numeric"
            value={phone}
            onChange={(event) => setPhone(event.target.value)}
          />
        </div>

        {error && <p className="text-xs text-destructive">{error}</p>}

        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" size="sm" onClick={onCancel} disabled={pending}>
            {t("cancel")}
          </Button>
          <Button type="submit" size="sm" disabled={pending}>
            {pending ? t("adding") : t("add")}
          </Button>
        </div>
      </form>
    );
  }

  if (isCombo) {
    const textFields: ReadonlyArray<{ id: string; label: string; value: string; set: (v: string) => void; numeric?: boolean }> = [
      { id: "name", label: t("name"), value: name, set: setName },
      { id: "phone", label: t("phone"), value: phone, set: setPhone, numeric: true },
      { id: "address", label: t("address"), value: address, set: setAddress },
      { id: "reference", label: t("reference"), value: reference, set: setReference },
      { id: "contact-phone", label: t("contactPhone"), value: contactPhone, set: setContactPhone, numeric: true },
    ];
    return (
      <form onSubmit={handleSubmit} className="space-y-2 rounded-md border border-border bg-muted/40 p-2">
        {textFields.map((field) => (
          <div key={field.id} className="space-y-1">
            <Label htmlFor={`add-beneficiary-${field.id}`}>{field.label}</Label>
            <Input
              id={`add-beneficiary-${field.id}`}
              inputMode={field.numeric ? "numeric" : undefined}
              value={field.value}
              onChange={(event) => field.set(event.target.value)}
            />
          </div>
        ))}
        <div className="space-y-1">
          <Label htmlFor="add-beneficiary-amount">{t("amount")} (GYD)</Label>
          <Input
            id="add-beneficiary-amount"
            inputMode="decimal"
            value={amount}
            onChange={(event) => setAmount(event.target.value)}
          />
          <p className="text-[11px] text-muted-foreground">{t("comboMinimumHint")}</p>
        </div>

        {error && <p className="text-xs text-destructive">{error}</p>}

        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" size="sm" onClick={onCancel} disabled={pending}>
            {t("cancel")}
          </Button>
          <Button type="submit" size="sm" disabled={pending}>
            {pending ? t("adding") : t("add")}
          </Button>
        </div>
      </form>
    );
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-2 rounded-md border border-border bg-muted/40 p-2">
      <div className="space-y-1">
        <Label htmlFor="add-beneficiary-type">{t("beneficiaryTypeLabel")}</Label>
        <select
          id="add-beneficiary-type"
          value={beneficiaryType}
          onChange={(event) => setBeneficiaryType(event.target.value)}
          className="h-8 w-full rounded-lg border border-input bg-transparent px-2.5 text-sm outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
        >
          {ADDABLE_BENEFICIARY_TYPES.map((type) => (
            <option key={type} value={type}>
              {t(`beneficiaryType.${type}`)}
            </option>
          ))}
        </select>
      </div>

      {isZelle ? (
        <>
          <div className="space-y-1">
            <Label htmlFor="add-beneficiary-name">{t("name")}</Label>
            <Input id="add-beneficiary-name" value={name} onChange={(event) => setName(event.target.value)} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="add-beneficiary-zelle-account">{t("zelleAccount")}</Label>
            <Input
              id="add-beneficiary-zelle-account"
              value={zelleAccount}
              onChange={(event) => setZelleAccount(event.target.value)}
            />
          </div>
        </>
      ) : (
        <>
          <div className="space-y-1">
            <Label htmlFor="add-beneficiary-card-number">{t("card")}</Label>
            <Input
              id="add-beneficiary-card-number"
              inputMode="numeric"
              value={cardNumber}
              onChange={(event) => setCardNumber(event.target.value)}
            />
          </div>
          <div className="space-y-1">
            <Label htmlFor="add-beneficiary-phone">{t("phone")}</Label>
            <Input
              id="add-beneficiary-phone"
              inputMode="numeric"
              value={phone}
              onChange={(event) => setPhone(event.target.value)}
            />
          </div>
        </>
      )}

      <div className="space-y-1">
        <Label htmlFor="add-beneficiary-amount">{t("amount")}</Label>
        <Input
          id="add-beneficiary-amount"
          inputMode="decimal"
          value={amount}
          onChange={(event) => setAmount(event.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="add-beneficiary-currency">{t("currency")}</Label>
        <Input
          id="add-beneficiary-currency"
          value={currency}
          onChange={(event) => setCurrency(event.target.value)}
        />
      </div>

      {error && <p className="text-xs text-destructive">{error}</p>}

      <div className="flex justify-end gap-2">
        <Button type="button" variant="outline" size="sm" onClick={onCancel} disabled={pending}>
          {t("cancel")}
        </Button>
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? t("adding") : t("add")}
        </Button>
      </div>
    </form>
  );
}
