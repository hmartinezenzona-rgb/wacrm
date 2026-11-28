"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { formatNumber } from "@/lib/format-number";
import { editarReparto } from "@/lib/remittance-operations/commands";
import type { RemittanceBeneficiaryRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, UNDERLINE_SELECT_TRIGGER, UnderlineInput } from "./edit-form-fields";
import { parseAmount } from "./split-deposit-form";

/** The rails a split of card shares can hold (crm_editar_reparto refuses any other). */
const CARD_RAILS: ReadonlyArray<string> = ["cuban_card", "clasica", "tropical", "multiple_distribution"];
const CARD_PATTERN = /^\d{16}$/;
const PHONE_PATTERN = /^\d{8,15}$/;
const MIN_SHARES = 2;

/** Whether the card offers "Editar reparto": a remesa whose current recipients (none, one or several) are all card
 *  rails. With fewer than two the form pads empty rows, so a split can be built from scratch. */
export function canEditSplit(operation: Pick<RemittanceOperationRead, "serviceType" | "beneficiaries">): boolean {
  return (
    operation.serviceType === "remesa" &&
    operation.beneficiaries.every((beneficiary) => CARD_RAILS.includes(beneficiary.beneficiaryType))
  );
}

interface ShareRow {
  key: number;
  /** The current share's id; null for a row added in this form. */
  id: string | null;
  type: string;
  name: string;
  card: string;
  phone: string;
  amount: string;
}

interface SplitEditFormProps {
  operationId: string;
  /** The operation's current (vigente) recipients, all card rails. */
  beneficiaries: RemittanceBeneficiaryRead[];
  /** The operation's destination total the shares must add up to; null when it has none. */
  total: number | null;
  currency: string | null;
  onDone: () => void;
  onCancel: () => void;
}

/** Money compared in cents, so a typed 0.1 + 0.2 still equals 0.3. */
const cents = (value: number) => Math.round(value * 100);
const digitsOf = (text: string) => text.replace(/\D/g, "");

/**
 * Inline editor of every card share of a remesa (`editarReparto`, migration 394): one block per share (type, name,
 * card, phone, amount), add and remove rows, and a live "Sum X / Total Y — difference Z" line. Save stays locked until
 * there are at least two shares, each with a 16-digit card, a phone that is empty or 8 to 15 digits and an amount above
 * zero, adding up exactly to the operation's total (the rules the RPC enforces). One request saves everything: rows that
 * came from the operation keep their id, rows added here send null. The server's refusal is shown in the form.
 */
export function SplitEditForm({ operationId, beneficiaries, total, currency, onDone, onCancel }: SplitEditFormProps) {
  const t = useTranslations("Inbox.operationsPanel");

  // Padded with empty rows up to the two shares a split needs, so one or no recipient can grow into a split.
  const initialRows = Math.max(beneficiaries.length, MIN_SHARES);
  const [rows, setRows] = useState<ShareRow[]>(() =>
    Array.from({ length: initialRows }, (_, index): ShareRow => {
      const beneficiary = beneficiaries[index];
      if (!beneficiary) return { key: index, id: null, type: "cuban_card", name: "", card: "", phone: "", amount: "" };
      return {
        key: index,
        id: beneficiary.id,
        type: beneficiary.beneficiaryType,
        name: beneficiary.name ?? "",
        card: beneficiary.cardNumber ?? "",
        phone: beneficiary.phone ?? "",
        amount: beneficiary.amount === null ? "" : String(beneficiary.amount),
      };
    }),
  );
  const [nextKey, setNextKey] = useState(initialRows);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const amounts = rows.map((row) => parseAmount(row.amount));
  const sum = amounts.reduce((acc, amount) => acc + (Number.isFinite(amount) ? amount : 0), 0);
  const sumMatches = total !== null && cents(sum) === cents(total);
  const rowsValid = rows.every((row, index) => {
    const phone = digitsOf(row.phone);
    return (
      CARD_RAILS.includes(row.type) &&
      CARD_PATTERN.test(digitsOf(row.card)) &&
      (phone === "" || PHONE_PATTERN.test(phone)) &&
      Number.isFinite(amounts[index]) &&
      amounts[index]! > 0
    );
  });
  const valid = rows.length >= MIN_SHARES && rowsValid && sumMatches && currency !== null;
  const unit = currency ? ` ${currency}` : "";

  function updateRow(key: number, change: Partial<ShareRow>) {
    setRows((current) => current.map((row) => (row.key === key ? { ...row, ...change } : row)));
  }

  function addRow() {
    setRows((current) => [...current, { key: nextKey, id: null, type: "cuban_card", name: "", card: "", phone: "", amount: "" }]);
    setNextKey((current) => current + 1);
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (!valid || pending) return;
    setError(null);
    setPending(true);
    const result = await editarReparto(
      operationId,
      rows.map((row, index) => ({
        id: row.id,
        beneficiary_type: row.type,
        name: row.name.trim() === "" ? null : row.name.trim(),
        card_number: digitsOf(row.card),
        phone: digitsOf(row.phone) === "" ? null : digitsOf(row.phone),
        amount: amounts[index]!,
        currency: currency!,
      })),
    );
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    toast.success(t("editSplit.saved"));
    onDone();
  }

  const field = (row: ShareRow, label: string, value: string, key: keyof ShareRow, inputMode?: "numeric" | "decimal") => (
    <UnderlineInput
      aria-label={label}
      placeholder={label}
      inputMode={inputMode}
      value={value}
      disabled={pending}
      onChange={(event) => updateRow(row.key, { [key]: event.target.value })}
    />
  );

  return (
    <form onSubmit={handleSubmit} onKeyDown={cancelOnEscape(onCancel)} className={EDIT_AREA}>
      {rows.map((row) => (
        <div key={row.key} className="space-y-1 border-b border-border pb-1.5">
          <div className="grid grid-cols-[1fr_auto] items-center gap-x-2">
            <Select
              id={`edit-split-type-${row.key}`}
              value={row.type}
              disabled={pending}
              onValueChange={(value) => updateRow(row.key, { type: value ?? "cuban_card" })}
            >
              <SelectTrigger className={UNDERLINE_SELECT_TRIGGER} aria-label={t("editSplit.type")}>
                {/* Base UI paints the raw value unless it is given the label. */}
                <SelectValue>{(value) => t(`editSplit.types.${(value as string) || row.type}`)}</SelectValue>
              </SelectTrigger>
              <SelectContent>
                {CARD_RAILS.map((type) => (
                  <SelectItem key={type} value={type}>
                    {t(`editSplit.types.${type}`)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {rows.length > MIN_SHARES ? (
              <Button
                type="button"
                variant="ghost"
                size="icon-xs"
                aria-label={t("editSplit.removeRow")}
                title={t("editSplit.removeRow")}
                disabled={pending}
                onClick={() => setRows((current) => current.filter((candidate) => candidate.key !== row.key))}
              >
                <Trash2 aria-hidden="true" />
              </Button>
            ) : (
              <span className="size-6" aria-hidden="true" />
            )}
          </div>
          <div className="grid grid-cols-2 gap-x-2">
            {field(row, t("editSplit.name"), row.name, "name")}
            {field(row, t("editSplit.amount"), row.amount, "amount", "decimal")}
          </div>
          <div className="grid grid-cols-2 gap-x-2">
            {field(row, t("editSplit.card"), row.card, "card", "numeric")}
            {field(row, t("editSplit.phone"), row.phone, "phone", "numeric")}
          </div>
        </div>
      ))}
      <div className="flex items-center justify-between gap-2">
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          aria-label={t("editSplit.addRow")}
          title={t("editSplit.addRow")}
          disabled={pending}
          onClick={addRow}
        >
          <Plus aria-hidden="true" />
        </Button>
        <p className={`text-xs ${sumMatches ? "text-muted-foreground" : "text-destructive"}`} aria-live="polite">
          {total === null
            ? t("editSplit.noTotal")
            : t("editSplit.summary", {
                sum: `${formatNumber(sum)}${unit}`,
                total: `${formatNumber(total)}${unit}`,
                difference: formatNumber(Math.round((sum - total) * 100) / 100),
              })}
        </p>
      </div>
      <div className="flex items-center gap-2">
        {error && <p className="min-w-0 flex-1 text-xs text-destructive">{error}</p>}
        <ConfirmCancelButtons
          type="submit"
          onCancel={onCancel}
          pending={pending}
          confirmDisabled={!valid}
          confirmLabel={t("editSplit.confirm")}
        />
      </div>
    </form>
  );
}
