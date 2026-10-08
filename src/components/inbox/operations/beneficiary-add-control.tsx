"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { useServiceName } from "@/hooks/use-service-name";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, FieldRow, UNDERLINE_SELECT_TRIGGER, UnderlineInput } from "./edit-form-fields";
import { IdPhotoFormRow } from "./beneficiary-id-photo";
import { agregarBeneficiario } from "@/lib/remittance-operations/commands";
import type { OperationService } from "@/lib/remittance-operations/services";

interface BeneficiaryAddControlProps {
  operationId: string;
  /** The operation's conversation. When given, a cash recipient can take its ID photo from that chat. */
  conversationId?: string;
  /** `recarga` and `saldo` turn the form into a single Cuban-mobile-number field; `combo`
   *  into a recipient form (name, phone, address, reference, contact phone, amount). */
  serviceType?: string;
  /** The operation's current service (`currentServiceOf`). When it is a recipient service the form shows that
   *  service's fields directly; the type picker only appears while the operation has no service yet. */
  service?: OperationService | null;
  /** The operation's current quoted destination amount, offered only when the recipient being added is the lone one
   *  (the amount is then what the system already computed). Prefills the amount; the person may change it. */
  quote?: { amount: number; currency: string } | null;
  onDone: () => void;
  onCancel: () => void;
}

const CARD_NUMBER_PATTERN = /^\d{16}$/;
const PHONE_PATTERN = /^\d{8,15}$/;

/** The destination currency each card/Zelle service pays in (crm_agregar_beneficiario still requires it). */
const SERVICE_CURRENCY: Readonly<Record<string, string>> = { cuban_card: "CUP", zelle: "USD", clasica: "USD", tropical: "USD" };
const RECHARGE_PHONE_PATTERN = /^[56]\d{7}$/;

/** Types offered by this control. `multiple_distribution` (reparto) is
 *  deliberately excluded — splitting one payment across several
 *  beneficiaries is its own bot-driven flow, not a single hand-added
 *  beneficiary (see the feature doc's "Decisions to confirm"). */
const ADDABLE_BENEFICIARY_TYPES: ReadonlyArray<string> = ["cuban_card", "zelle", "clasica", "tropical", "efectivo_usd"];

/**
 * Inline "Add beneficiary" form for an open remesa: pick a type, fill in
 * its identifying fields (Zelle: name + account; every other type: card +
 * phone), and an amount + currency — mirrors `crm_agregar_beneficiario`'s
 * `datos` contract exactly (snake_case keys, amount as a number). Sends
 * only the fields the selected type needs.
 */
export function BeneficiaryAddControl({ operationId, conversationId, serviceType, service, quote, onDone, onCancel }: BeneficiaryAddControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const serviceName = useServiceName();

  const [pickedType, setPickedType] = useState("cuban_card");
  const [name, setName] = useState("");
  const [zelleAccount, setZelleAccount] = useState("");
  const [cardNumber, setCardNumber] = useState("");
  const [phone, setPhone] = useState("");
  const [typedAmount, setTypedAmount] = useState<string | null>(null);
  const [address, setAddress] = useState("");
  const [reference, setReference] = useState("");
  const [contactPhone, setContactPhone] = useState("");
  const [photoWamid, setPhotoWamid] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // The operation's service decides the type; the picker only exists while it has none.
  const serviceFixesType = service != null && ADDABLE_BENEFICIARY_TYPES.includes(service);
  const beneficiaryType = serviceFixesType ? service : pickedType;
  const isZelle = beneficiaryType === "zelle";
  const isCash = beneficiaryType === "efectivo_usd";
  const currency = SERVICE_CURRENCY[beneficiaryType] ?? "";
  // Prefill with the quote only when it is in this service's currency; whatever the person types wins.
  const prefill = quote && quote.amount > 0 && quote.currency === currency ? String(quote.amount) : "";
  const amount = typedAmount ?? prefill;
  const setAmount = setTypedAmount;
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

    if (isCash) {
      // Name optional, phone and address required; the amount is calculated by the database. The ID photo is optional
      // and chosen from the chat (migrations 225, 233).
      const digitsPhone = phone.replace(/\D/g, "");
      if (!PHONE_PATTERN.test(digitsPhone)) {
        setError(t("invalidPhone"));
        return;
      }
      if (address.trim() === "") {
        setError(t("cannotBeEmpty"));
        return;
      }
      const cashDatos: Record<string, unknown> = { beneficiary_type: "efectivo_usd", phone: digitsPhone, address: address.trim() };
      if (name.trim() !== "") cashDatos.name = name.trim();
      if (photoWamid !== null) cashDatos.id_photo_wamid = photoWamid;
      setPending(true);
      const result = await agregarBeneficiario(operationId, cashDatos);
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

  const actions = (
    <div className="flex items-center gap-2">
      {error && <p className="min-w-0 flex-1 text-xs text-destructive">{error}</p>}
      <ConfirmCancelButtons type="submit" onCancel={onCancel} confirmLabel={t("add")} pending={pending} />
    </div>
  );
  const formProps = { onSubmit: handleSubmit, onKeyDown: cancelOnEscape(onCancel), className: EDIT_AREA };

  if (isRecharge) {
    return (
      <form {...formProps}>
        <FieldRow label={t("phone")} htmlFor="add-beneficiary-phone">
          <UnderlineInput
            id="add-beneficiary-phone"
            inputMode="numeric"
            value={phone}
            onChange={(event) => setPhone(event.target.value)}
          />
        </FieldRow>
        {actions}
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
      <form {...formProps}>
        {textFields.map((field) => (
          <FieldRow key={field.id} label={field.label} htmlFor={`add-beneficiary-${field.id}`}>
            <UnderlineInput
              id={`add-beneficiary-${field.id}`}
              inputMode={field.numeric ? "numeric" : undefined}
              value={field.value}
              onChange={(event) => field.set(event.target.value)}
            />
          </FieldRow>
        ))}
        <FieldRow label={`${t("amount")} (GYD)`} htmlFor="add-beneficiary-amount">
          <UnderlineInput
            id="add-beneficiary-amount"
            inputMode="decimal"
            value={amount}
            onChange={(event) => setAmount(event.target.value)}
          />
        </FieldRow>
        <p className="text-[11px] text-muted-foreground">{t("comboMinimumHint")}</p>
        {actions}
      </form>
    );
  }

  const typePicker = serviceFixesType ? null : (
      <FieldRow label={t("beneficiaryTypeLabel")} htmlFor="add-beneficiary-type">
        <Select id="add-beneficiary-type" value={beneficiaryType} disabled={pending} onValueChange={(v) => setPickedType(v ?? "cuban_card")}>
          <SelectTrigger className={UNDERLINE_SELECT_TRIGGER}>
            {/* Base UI paints the raw value unless it is given the label. */}
            <SelectValue>{(v) => serviceName((v as string) || beneficiaryType)}</SelectValue>
          </SelectTrigger>
          <SelectContent>
            {ADDABLE_BENEFICIARY_TYPES.map((type) => (
              <SelectItem key={type} value={type}>
                {serviceName(type)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </FieldRow>
  );

  if (isCash) {
    return (
      <form {...formProps}>
        {typePicker}
        <FieldRow label={t("name")} htmlFor="add-beneficiary-name">
          <UnderlineInput id="add-beneficiary-name" value={name} onChange={(event) => setName(event.target.value)} />
        </FieldRow>
        <FieldRow label={t("phone")} htmlFor="add-beneficiary-phone">
          <UnderlineInput
            id="add-beneficiary-phone"
            inputMode="numeric"
            value={phone}
            onChange={(event) => setPhone(event.target.value)}
          />
        </FieldRow>
        <FieldRow label={t("address")} htmlFor="add-beneficiary-address">
          <UnderlineInput id="add-beneficiary-address" value={address} onChange={(event) => setAddress(event.target.value)} />
        </FieldRow>
        {conversationId && <IdPhotoFormRow conversationId={conversationId} value={photoWamid} disabled={pending} onChange={setPhotoWamid} />}
        {actions}
      </form>
    );
  }

  return (
    <form {...formProps}>
      {typePicker}

      {isZelle ? (
        <>
          <FieldRow label={t("name")} htmlFor="add-beneficiary-name">
            <UnderlineInput id="add-beneficiary-name" value={name} onChange={(event) => setName(event.target.value)} />
          </FieldRow>
          <FieldRow label={t("zelleAccount")} htmlFor="add-beneficiary-zelle-account">
            <UnderlineInput
              id="add-beneficiary-zelle-account"
              value={zelleAccount}
              onChange={(event) => setZelleAccount(event.target.value)}
            />
          </FieldRow>
        </>
      ) : (
        <>
          <FieldRow label={t("card")} htmlFor="add-beneficiary-card-number">
            <UnderlineInput
              id="add-beneficiary-card-number"
              inputMode="numeric"
              value={cardNumber}
              onChange={(event) => setCardNumber(event.target.value)}
            />
          </FieldRow>
          <FieldRow label={t("phone")} htmlFor="add-beneficiary-phone">
            <UnderlineInput
              id="add-beneficiary-phone"
              inputMode="numeric"
              value={phone}
              onChange={(event) => setPhone(event.target.value)}
            />
          </FieldRow>
        </>
      )}

      <FieldRow label={`${t("amount")} (${currency})`} htmlFor="add-beneficiary-amount">
        <UnderlineInput
          id="add-beneficiary-amount"
          inputMode="decimal"
          value={amount}
          onChange={(event) => setAmount(event.target.value)}
        />
      </FieldRow>

      {actions}
    </form>
  );
}
