"use client";

import { useState, type KeyboardEvent } from "react";
import { useTranslations } from "next-intl";
import { Banknote, FileText, MapPin, Phone, Smartphone, UserRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { corregirBeneficiario } from "@/lib/remittance-operations/commands";
import type { RemittanceBeneficiaryRead } from "@/lib/remittance-operations/types";
import { InlineEditField } from "./inline-edit-field";

const PHONE_PATTERN = /^\d{8,15}$/;

interface ComboBeneficiaryEditFieldsProps {
  beneficiary: RemittanceBeneficiaryRead;
  onCancel: () => void;
  onSaved: () => void;
}

/**
 * Inline edit of one combo recipient: name, phone, address, reference, contact
 * phone and the GYD amount, the keys `crm_corregir_beneficiario` accepts for a
 * combo (212). Sends only the changed keys through `corregirBeneficiario`; the
 * minimum-amount and province hints never block a save.
 */
export function ComboBeneficiaryEditFields({ beneficiary, onCancel, onSaved }: ComboBeneficiaryEditFieldsProps) {
  const t = useTranslations("Inbox.operationsPanel");

  const initialName = beneficiary.name ?? "";
  const initialPhoneDigits = (beneficiary.phone ?? "").replace(/\D/g, "");
  const initialAddress = beneficiary.address ?? "";
  const initialReference = beneficiary.reference ?? "";
  const initialContactDigits = (beneficiary.contactPhone ?? "").replace(/\D/g, "");
  const initialAmount = beneficiary.amount === null ? "" : String(beneficiary.amount);

  const [name, setName] = useState(initialName);
  const [phone, setPhone] = useState(beneficiary.phone ?? "");
  const [address, setAddress] = useState(initialAddress);
  const [reference, setReference] = useState(initialReference);
  const [contactPhone, setContactPhone] = useState(beneficiary.contactPhone ?? "");
  const [amount, setAmount] = useState(initialAmount);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSave() {
    setError(null);
    const changes: Record<string, unknown> = {};

    const trimmedName = name.trim();
    if (trimmedName === "") {
      setError(t("cannotBeEmpty"));
      return;
    }
    if (trimmedName !== initialName) changes.name = trimmedName;

    const digitsPhone = phone.replace(/\D/g, "");
    if (digitsPhone === "") {
      setError(t("cannotBeEmpty"));
      return;
    }
    if (!PHONE_PATTERN.test(digitsPhone)) {
      setError(t("invalidPhone"));
      return;
    }
    if (digitsPhone !== initialPhoneDigits) changes.phone = digitsPhone;

    const trimmedAddress = address.trim();
    if (trimmedAddress !== initialAddress) changes.address = trimmedAddress === "" ? null : trimmedAddress;

    const trimmedReference = reference.trim();
    if (trimmedReference !== initialReference) changes.reference = trimmedReference === "" ? null : trimmedReference;

    const digitsContact = contactPhone.replace(/\D/g, "");
    if (digitsContact !== initialContactDigits) {
      if (digitsContact !== "" && !PHONE_PATTERN.test(digitsContact)) {
        setError(t("invalidPhone"));
        return;
      }
      changes.contact_phone = digitsContact === "" ? null : digitsContact;
    }

    const trimmedAmount = amount.trim();
    if (trimmedAmount !== initialAmount) {
      const parsed = Number(trimmedAmount);
      if (!(parsed > 0)) {
        setError(t("invalidAmount"));
        return;
      }
      changes.amount = parsed;
    }

    if (Object.keys(changes).length === 0) {
      onCancel();
      return;
    }

    setPending(true);
    const result = await corregirBeneficiario(beneficiary.id, changes);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }

    onSaved();
  }

  function handleKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (pending) return;
    if (event.key === "Enter") {
      event.preventDefault();
      void handleSave();
    } else if (event.key === "Escape") {
      event.preventDefault();
      onCancel();
    }
  }

  const id = beneficiary.id;
  return (
    <div className="space-y-1.5" onKeyDown={handleKeyDown}>
      <InlineEditField
        id={`inline-amount-${id}`}
        icon={<Banknote className="size-3.5" aria-hidden="true" />}
        value={amount}
        onChange={setAmount}
        placeholder={t("amount")}
        ariaLabel={t("amount")}
        disabled={pending}
        inputMode="decimal"
        autoFocus
      />
      <p className="px-1 text-[11px] text-muted-foreground">{t("comboMinimumHint")}</p>
      <InlineEditField
        id={`inline-name-${id}`}
        icon={<UserRound className="size-3.5" aria-hidden="true" />}
        value={name}
        onChange={setName}
        placeholder={t("name")}
        ariaLabel={t("name")}
        disabled={pending}
        variant="name"
      />
      <InlineEditField
        id={`inline-phone-${id}`}
        icon={<Phone className="size-3.5" aria-hidden="true" />}
        value={phone}
        onChange={setPhone}
        placeholder={t("phone")}
        ariaLabel={t("phone")}
        disabled={pending}
        inputMode="numeric"
      />
      <InlineEditField
        id={`inline-address-${id}`}
        icon={<MapPin className="size-3.5" aria-hidden="true" />}
        value={address}
        onChange={setAddress}
        placeholder={t("address")}
        ariaLabel={t("address")}
        disabled={pending}
      />
      <p className="px-1 text-[11px] text-muted-foreground">{t("comboProvinceHint")}</p>
      <InlineEditField
        id={`inline-reference-${id}`}
        icon={<FileText className="size-3.5" aria-hidden="true" />}
        value={reference}
        onChange={setReference}
        placeholder={t("reference")}
        ariaLabel={t("reference")}
        disabled={pending}
      />
      <InlineEditField
        id={`inline-contact-phone-${id}`}
        icon={<Smartphone className="size-3.5" aria-hidden="true" />}
        value={contactPhone}
        onChange={setContactPhone}
        placeholder={t("contactPhone")}
        ariaLabel={t("contactPhone")}
        disabled={pending}
        inputMode="numeric"
      />

      {error && (
        <p role="alert" className="text-xs text-destructive">
          {error}
        </p>
      )}

      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" size="sm" onClick={onCancel} disabled={pending}>
          {t("cancel")}
        </Button>
        <Button type="button" size="sm" onClick={() => void handleSave()} disabled={pending}>
          {pending ? t("saving") : t("save")}
        </Button>
      </div>
    </div>
  );
}
