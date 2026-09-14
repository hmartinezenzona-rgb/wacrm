"use client";

import { useState, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import {
  ArrowRightLeft,
  AtSign,
  Banknote,
  ChevronDown,
  CreditCard,
  Lock,
  Pencil,
  Phone,
  UserRound,
  Users,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { OperationCorrectionForm } from "./operation-correction-form";
import { BeneficiaryCorrectionForm } from "./beneficiary-correction-form";
import { BeneficiaryReassignControl } from "./beneficiary-reassign-control";
import { CopyButton } from "./copy-button";
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
  /** Whether this card's details (correction form + beneficiaries) are
   *  shown. The panel is an accordion — expansion is owned by the
   *  container, not local state, so only one card is open at a time. */
  expanded: boolean;
  /** Toggles this card's expanded state; called when the header is
   *  clicked. */
  onToggle: () => void;
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

/** Groups a raw digit string into 4s separated by a single space for
 *  display (e.g. "9205123412349412" -> "9205 1234 1234 9412"). The copy
 *  button always copies the raw, unformatted value. */
function formatCardNumber(value: string): string {
  const groups: string[] = [];
  for (let i = 0; i < value.length; i += 4) {
    groups.push(value.slice(i, i + 4));
  }
  return groups.join(" ");
}

/** Human label for a known beneficiary/delivery type, the deposit method
 *  "mmg" special case, or the raw value as a last resort. */
function knownMethodLabel(method: string, t: (key: string) => string): string {
  return KNOWN_BENEFICIARY_TYPES.includes(method)
    ? t(`beneficiaryType.${method}`)
    : method === "mmg"
      ? t("depositMethodValue.mmg")
      : method;
}

/** What the header shows to the right of the arrow: the delivery method's
 *  human label for the fixed Zelle/Classic/Tropical rails, otherwise the
 *  destination currency (operation-level, then the first beneficiary's),
 *  otherwise the delivery method's label as a last resort. Never the
 *  destination amount — that's not shown anywhere in the card. */
function destinationLabel(operation: RemittanceOperationRead, t: (key: string) => string): string | null {
  const { deliveryMethod, destinationCurrency, beneficiaries } = operation;

  if (deliveryMethod === "zelle" || deliveryMethod === "clasica" || deliveryMethod === "tropical") {
    return t(`beneficiaryType.${deliveryMethod}`);
  }
  if (destinationCurrency) return destinationCurrency;
  const firstCurrency = beneficiaries[0]?.currency;
  if (firstCurrency) return firstCurrency;
  if (deliveryMethod) return knownMethodLabel(deliveryMethod, t);
  return null;
}

/**
 * Presentational: one open remesa operation. Header is minimal — the
 * source amount, an arrow, and the destination name (rail label,
 * destination currency, or delivery method), each with a lock indicator
 * when admin-locked; the destination amount is never rendered. Below the
 * header, always visible, a status chip and (when present) a deposit
 * method chip. When `expanded` (owned by the panel container so only one
 * card is open at a time): an edit-operation affordance, the operation
 * correction form, and every current ('vigente') beneficiary as compact
 * rows — an amount row (with inline edit/move actions when `canEdit`),
 * then either a name + Zelle account (type "zelle") or a card + phone
 * (every other type), each with a copy button. No beneficiary type badge.
 */
export function RemittanceOperationCard({
  operation,
  canEdit,
  otherOpenOperations,
  onChanged,
  expanded,
  onToggle,
}: RemittanceOperationCardProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [openForm, setOpenForm] = useState<OpenFormState | null>(null);

  const editable = canEdit && !TERMINAL_STATUSES.includes(operation.status);
  const isLocked = (key: string) => key in operation.adminLockedFields;

  function toggleForm(next: OpenFormState) {
    setOpenForm((current) =>
      current && current.kind === next.kind && current.beneficiaryId === next.beneficiaryId ? null : next,
    );
  }

  function handleChanged() {
    setOpenForm(null);
    onChanged();
  }

  const source = money(operation.quotedSourceAmount, operation.sourceCurrency);
  const destLabel = destinationLabel(operation, t as (key: string) => string);
  const destLocked = isLocked("delivery_method") || isLocked("destination_currency") || isLocked("quoted_destination_amount");

  const methodLabel = (method: string): string => knownMethodLabel(method, t as (key: string) => string);

  const lock = <Lock className="size-3 shrink-0" aria-label={t("lockedByOperator")} />;

  return (
    <article className="rounded-lg border border-border bg-card px-2 py-2.5">
      <div className="flex items-center gap-1">
        <button
          type="button"
          aria-expanded={expanded}
          onClick={onToggle}
          className="flex min-w-0 flex-1 items-center gap-2 rounded-md text-left outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          <span className="flex min-w-0 flex-1 flex-wrap items-center gap-x-1 text-sm font-semibold tabular-nums text-foreground">
            <span className="inline-flex items-center gap-1">
              {source ?? t("amountUnavailable")}
              {isLocked("quoted_source_amount") && lock}
            </span>
            {destLabel && (
              <>
                <span aria-hidden="true" className="text-muted-foreground">
                  →
                </span>
                <span className="inline-flex items-center gap-1">
                  {destLabel}
                  {destLocked && lock}
                </span>
              </>
            )}
          </span>
          <ChevronDown
            className={`size-4 shrink-0 text-muted-foreground transition-transform ${expanded ? "rotate-180" : ""}`}
            aria-hidden="true"
          />
        </button>
        {expanded && editable && (
          <Button
            type="button"
            variant="ghost"
            size="icon-xs"
            aria-label={t("editOperation")}
            title={t("editOperation")}
            onClick={() => toggleForm({ kind: "operation" })}
          >
            <Pencil aria-hidden="true" />
          </Button>
        )}
      </div>

      <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
        <StatusChip status={operation.status} label={t(`status.${operation.status}`)} />
        {(operation.depositMethod !== null || isLocked("deposit_method")) && (
          <span
            className="inline-flex items-center gap-1 rounded-full border border-border bg-muted/40 py-0.5 pl-0.5 pr-2 text-[11px] font-medium text-foreground"
            title={t("depositMethod")}
          >
            <MethodIcon method={operation.depositMethod} label={t("depositMethod")} />
            <span className="sr-only">{t("depositMethod")}: </span>
            {operation.depositMethod ? methodLabel(operation.depositMethod) : "—"}
            {isLocked("deposit_method") && lock}
          </span>
        )}
        {!expanded && operation.beneficiaries.length > 1 && (
          <span className="inline-flex items-center gap-1 text-xs text-muted-foreground" title={t("beneficiaries")}>
            <Users className="size-3.5" aria-hidden="true" />
            {operation.beneficiaries.length}
          </span>
        )}
      </div>

      {expanded && (
        <div className="mt-2.5 space-y-2.5">
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
                  const isZelle = beneficiary.beneficiaryType === "zelle";
                  const isEditingBeneficiary =
                    openForm?.kind === "beneficiary" && openForm.beneficiaryId === beneficiary.id;
                  const isMovingBeneficiary =
                    openForm?.kind === "reassign" && openForm.beneficiaryId === beneficiary.id;

                  return (
                    <li key={beneficiary.id} className="space-y-1 rounded-md bg-muted/60 px-1.5 py-2 text-xs">
                      {editable && (
                        <div className="flex justify-end">
                          <Button
                            type="button"
                            variant="ghost"
                            size="icon-xs"
                            aria-label={t("editBeneficiary")}
                            title={t("editBeneficiary")}
                            onClick={() => toggleForm({ kind: "beneficiary", beneficiaryId: beneficiary.id })}
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
                              onClick={() => toggleForm({ kind: "reassign", beneficiaryId: beneficiary.id })}
                            >
                              <ArrowRightLeft aria-hidden="true" />
                            </Button>
                          )}
                        </div>
                      )}
                      {beneficiaryAmount !== null && (
                        <DataRow
                          icon={<Banknote className="size-3.5" aria-hidden="true" />}
                          label={t("amount")}
                          display={beneficiaryAmount}
                          valueClassName="whitespace-nowrap font-semibold tabular-nums"
                          trailing={null}
                        />
                      )}

                      {isZelle ? (
                        <>
                          <DataRow
                            icon={<UserRound className="size-3.5" aria-hidden="true" />}
                            label={t("name")}
                            display={beneficiary.name ?? t("beneficiaryNameUnavailable")}
                            trailing={
                              beneficiary.name ? (
                                <CopyButton value={beneficiary.name} ariaLabel={`${t("copy")} ${t("name")}`} />
                              ) : null
                            }
                          />
                          {beneficiary.zelleAccount && (
                            <DataRow
                              icon={<AtSign className="size-3.5" aria-hidden="true" />}
                              label={t("zelleAccount")}
                              display={beneficiary.zelleAccount}
                              trailing={
                                <CopyButton
                                  value={beneficiary.zelleAccount}
                                  ariaLabel={`${t("copy")} ${t("zelleAccount")}`}
                                />
                              }
                            />
                          )}
                        </>
                      ) : (
                        <>
                          {beneficiary.cardNumber && (
                            <DataRow
                              icon={<CreditCard className="size-3.5" aria-hidden="true" />}
                              label={t("card")}
                              display={formatCardNumber(beneficiary.cardNumber)}
                              valueClassName="whitespace-nowrap tabular-nums"
                              trailing={
                                <CopyButton value={beneficiary.cardNumber} ariaLabel={`${t("copy")} ${t("card")}`} />
                              }
                            />
                          )}
                          {beneficiary.phone && (
                            <DataRow
                              icon={<Phone className="size-3.5" aria-hidden="true" />}
                              label={t("phone")}
                              display={beneficiary.phone}
                              valueClassName="whitespace-nowrap tabular-nums"
                              trailing={
                                <CopyButton value={beneficiary.phone} ariaLabel={`${t("copy")} ${t("phone")}`} />
                              }
                            />
                          )}
                        </>
                      )}

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
        </div>
      )}
    </article>
  );
}

/** One beneficiary data row: the field icon flush left, the value flush
 *  right, and a fixed one-button trailing column (the copy button, or empty)
 *  that lines up with the move button in the actions row above, so every
 *  value ends on the same right edge. */
function DataRow({
  icon,
  label,
  display,
  valueClassName,
  trailing,
}: {
  icon: ReactNode;
  label: string;
  display: string;
  valueClassName?: string;
  trailing: ReactNode;
}) {
  return (
    <div className="flex items-center gap-1.5">
      <span className="flex w-5 shrink-0 justify-center text-muted-foreground" title={label}>
        {icon}
      </span>
      <span className="sr-only">{label}: </span>
      <span className={`ml-auto min-w-0 text-right font-medium text-foreground ${valueClassName ?? "break-words"}`}>
        {display}
      </span>
      <span className="flex w-6 shrink-0 items-center justify-center">{trailing}</span>
    </div>
  );
}
