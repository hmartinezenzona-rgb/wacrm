"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { ArrowRightLeft, AtSign, Coins, CreditCard, Lock, Pencil, Phone } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { OperationCorrectionForm } from "./operation-correction-form";
import { BeneficiaryCorrectionForm } from "./beneficiary-correction-form";
import { BeneficiaryReassignControl } from "./beneficiary-reassign-control";
import { KNOWN_BENEFICIARY_TYPES, MethodIcon, StatusChip } from "./operation-icons";

interface ReassignTarget {
  id: string;
  label: string;
}

interface RemittanceOperationCardProps {
  operation: RemittanceOperationRead;
  /** Current user can correct/reassign (role agent or higher). */
  canEdit: boolean;
  /** Other open (non-terminal) remesa operations of the same
   *  conversation, offered as reassignment targets for this card's
   *  beneficiaries. */
  otherOpenOperations: ReassignTarget[];
  /** Called after a correction or reassignment succeeds, so the panel
   *  container can refetch. */
  onChanged: () => void;
}

/** The RPC never returns these (see types.ts), but the correction API can
 *  still move an operation into one of them — defensive, not dead code. */
const TERMINAL_STATUSES: ReadonlyArray<string> = ["completed", "cancelled"];

type OpenFormKind = "operation" | "beneficiary" | "reassign";

interface OpenFormState {
  kind: OpenFormKind;
  beneficiaryId?: string;
}

function money(amount: number | null, currency: string | null): string | null {
  if (amount === null) return null;
  const formatted = new Intl.NumberFormat("en-US").format(amount);
  return currency ? `${formatted} ${currency}` : formatted;
}

/**
 * Presentational: one open remesa operation, amount(s), delivery method,
 * status, every current ('vigente') beneficiary with masked card/phone,
 * admin-lock indicators, and — when `canEdit` and the operation isn't
 * terminal — inline correction and reassignment affordances (Slice 6).
 * Methods, statuses, and beneficiary types render as icons plus human
 * labels instead of raw enum values; edit/move affordances are icon-only
 * buttons.
 */
export function RemittanceOperationCard({
  operation,
  canEdit,
  otherOpenOperations,
  onChanged,
}: RemittanceOperationCardProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [openForm, setOpenForm] = useState<OpenFormState | null>(null);

  const editable = canEdit && !TERMINAL_STATUSES.includes(operation.status);
  const isLocked = (key: string) => key in operation.adminLockedFields;

  function toggle(next: OpenFormState) {
    setOpenForm((current) =>
      current && current.kind === next.kind && current.beneficiaryId === next.beneficiaryId ? null : next,
    );
  }

  function handleChanged() {
    setOpenForm(null);
    onChanged();
  }

  const source = money(operation.quotedSourceAmount, operation.sourceCurrency);
  const destination = money(operation.quotedDestinationAmount, operation.destinationCurrency);

  const methodLabel = (method: string): string =>
    KNOWN_BENEFICIARY_TYPES.includes(method)
      ? t(`beneficiaryType.${method}`)
      : method === "mmg"
        ? t("depositMethodValue.mmg")
        : method;

  const lock = <Lock className="size-3 shrink-0" aria-label={t("lockedByOperator")} />;

  const chips: { key: string; fieldKey: string; label: string; icon: React.ReactNode; text: string }[] = [];

  if (operation.deliveryMethod !== null || isLocked("delivery_method")) {
    const value = operation.deliveryMethod;
    chips.push({
      key: "delivery",
      fieldKey: "delivery_method",
      label: t("deliveryMethod"),
      icon: <MethodIcon size="sm" method={value} label={t("deliveryMethod")} />,
      text: value ? methodLabel(value) : "—",
    });
  }

  if (operation.depositMethod !== null || isLocked("deposit_method")) {
    const value = operation.depositMethod;
    chips.push({
      key: "deposit",
      fieldKey: "deposit_method",
      label: t("depositMethod"),
      icon: <MethodIcon size="sm" method={value} label={t("depositMethod")} />,
      text: value ? methodLabel(value) : "—",
    });
  }

  if (operation.destinationCurrency !== null || isLocked("destination_currency")) {
    const value = operation.destinationCurrency;
    chips.push({
      key: "currency",
      fieldKey: "destination_currency",
      label: t("destinationCurrency"),
      icon: <Coins className="size-3.5 text-muted-foreground" aria-hidden="true" />,
      text: value ?? "—",
    });
  }

  return (
    <article className="space-y-3 rounded-lg border border-border bg-card p-3">
      <div className="flex items-start justify-between gap-2">
        <p className="flex flex-wrap items-center gap-x-1 text-base font-semibold leading-tight tabular-nums text-foreground">
          <span className="inline-flex items-center gap-1">
            {source ?? t("amountUnavailable")}
            {isLocked("quoted_source_amount") && lock}
          </span>
          {destination && (
            <>
              <span aria-hidden="true" className="text-muted-foreground">
                →
              </span>
              <span className="inline-flex items-center gap-1">
                {destination}
                {isLocked("quoted_destination_amount") && lock}
              </span>
            </>
          )}
        </p>
        <div className="flex shrink-0 items-center gap-1">
          <StatusChip status={operation.status} label={t(`status.${operation.status}`)} />
          {editable && (
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label={t("editOperation")}
              title={t("editOperation")}
              onClick={() => toggle({ kind: "operation" })}
            >
              <Pencil aria-hidden="true" />
            </Button>
          )}
        </div>
      </div>

      {chips.length > 0 && (
        <ul className="flex flex-wrap gap-1.5">
          {chips.map((chip) => (
            <li
              key={chip.key}
              className="inline-flex items-center gap-1 rounded-full border border-border bg-muted/40 py-0.5 pl-0.5 pr-2 text-xs font-medium text-foreground"
              title={chip.label}
            >
              {chip.icon}
              <span className="sr-only">{chip.label}: </span>
              {chip.text}
              {isLocked(chip.fieldKey) && lock}
            </li>
          ))}
        </ul>
      )}

      {openForm?.kind === "operation" && (
        <OperationCorrectionForm operation={operation} onDone={handleChanged} onCancel={() => setOpenForm(null)} />
      )}

      <div>
        <h4 className="flex items-center gap-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
          {t("beneficiaries")}
          {isLocked("beneficiaries") && <Lock size={12} aria-label={t("lockedByOperator")} />}
        </h4>
        {operation.beneficiaries.length === 0 ? (
          <p className="mt-1 text-xs text-muted-foreground">{t("noBeneficiaries")}</p>
        ) : (
          <ul className="mt-1.5 space-y-1.5">
            {operation.beneficiaries.map((beneficiary) => {
              const beneficiaryAmount = money(beneficiary.amount, beneficiary.currency);
              const isEditingBeneficiary =
                openForm?.kind === "beneficiary" && openForm.beneficiaryId === beneficiary.id;
              const isMovingBeneficiary =
                openForm?.kind === "reassign" && openForm.beneficiaryId === beneficiary.id;

              return (
                <li key={beneficiary.id} className="rounded-md bg-muted/60 p-2 text-xs">
                  <div className="flex items-start gap-2">
                    <MethodIcon
                      method={beneficiary.beneficiaryType}
                      label={t(`beneficiaryType.${beneficiary.beneficiaryType}`)}
                    />
                    <div className="min-w-0 flex-1">
                      <div className="flex items-baseline justify-between gap-2">
                        <p className="truncate text-sm font-medium text-foreground">
                          {beneficiary.name ?? t("beneficiaryNameUnavailable")}
                        </p>
                        {beneficiaryAmount && (
                          <p className="shrink-0 font-semibold tabular-nums text-foreground">{beneficiaryAmount}</p>
                        )}
                      </div>
                      <ul className="mt-0.5 flex flex-wrap gap-x-3 gap-y-0.5 text-muted-foreground">
                        {beneficiary.cardNumberMasked && (
                          <li className="inline-flex items-center gap-1" title={t("card")}>
                            <CreditCard className="size-3.5" aria-hidden="true" />
                            <span className="sr-only">{t("card")}: </span>
                            <span className="tabular-nums text-foreground">{beneficiary.cardNumberMasked}</span>
                          </li>
                        )}
                        {beneficiary.phoneMasked && (
                          <li className="inline-flex items-center gap-1" title={t("phone")}>
                            <Phone className="size-3.5" aria-hidden="true" />
                            <span className="sr-only">{t("phone")}: </span>
                            <span className="tabular-nums text-foreground">{beneficiary.phoneMasked}</span>
                          </li>
                        )}
                        {beneficiary.zelleAccount && (
                          <li className="inline-flex items-center gap-1" title={t("zelleAccount")}>
                            <AtSign className="size-3.5" aria-hidden="true" />
                            <span className="sr-only">{t("zelleAccount")}: </span>
                            <span className="break-all text-foreground">{beneficiary.zelleAccount}</span>
                          </li>
                        )}
                      </ul>
                    </div>
                    {editable && (
                      <div className="flex shrink-0 gap-0.5">
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-xs"
                          aria-label={t("editBeneficiary")}
                          title={t("editBeneficiary")}
                          onClick={() => toggle({ kind: "beneficiary", beneficiaryId: beneficiary.id })}
                        >
                          <Pencil aria-hidden="true" />
                        </Button>
                        {otherOpenOperations.length > 0 && (
                          <Button
                            type="button"
                            variant="ghost"
                            size="icon-xs"
                            aria-label={t("moveBeneficiary")}
                            title={t("moveBeneficiary")}
                            onClick={() => toggle({ kind: "reassign", beneficiaryId: beneficiary.id })}
                          >
                            <ArrowRightLeft aria-hidden="true" />
                          </Button>
                        )}
                      </div>
                    )}
                  </div>
                  {isEditingBeneficiary && (
                    <div className="mt-1.5">
                      <BeneficiaryCorrectionForm
                        beneficiary={beneficiary}
                        onDone={handleChanged}
                        onCancel={() => setOpenForm(null)}
                      />
                    </div>
                  )}
                  {isMovingBeneficiary && (
                    <div className="mt-1.5">
                      <BeneficiaryReassignControl
                        beneficiaryId={beneficiary.id}
                        targets={otherOpenOperations}
                        onDone={handleChanged}
                        onCancel={() => setOpenForm(null)}
                      />
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </article>
  );
}
