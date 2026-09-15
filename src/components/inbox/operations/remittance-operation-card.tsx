"use client";

import { useState, type KeyboardEvent } from "react";
import { useTranslations } from "next-intl";
import { ArrowRightLeft, AtSign, Banknote, ChevronDown, CreditCard, Lock, Pencil, Phone, UserRound, Users } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { AccountRole } from "@/lib/auth/roles";
import { corregirBeneficiario } from "@/lib/remittance-operations/commands";
import type { RemittanceBeneficiaryRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { OperationCorrectionForm } from "./operation-correction-form";
import { BeneficiaryReassignControl } from "./beneficiary-reassign-control";
import { CompleteTransferContainer } from "./complete-transfer-container";
import { CopyChip } from "./copy-chip";
import { DepositReviewContainer } from "./deposit-review-container";
import type { SummaryAmount } from "./deposit-review-section";
import { InlineEditField } from "./inline-edit-field";
import { KNOWN_BENEFICIARY_TYPES, MethodIcon, StatusChip } from "./operation-icons";

const CARD_NUMBER_PATTERN = /^\d{16}$/;
const PHONE_PATTERN = /^\d{8,15}$/;

interface ReassignTarget {
  id: string;
  label: string;
}

interface RemittanceOperationCardProps {
  operation: RemittanceOperationRead;
  /** Current user can correct/reassign (role agent or higher). */
  canEdit: boolean;
  /** Current user's account role, or `null` while unknown/unauthenticated
   *  — forwarded to the deposit review container so it can gate the
   *  force-verify escalation (`canForceVerify`, owner/admin only). */
  role: AccountRole | null;
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
  /** The conversation this operation belongs to — forwarded to the
   *  "Complete transfer" section, which needs it to send the delivery
   *  proof and to check the 24-hour window. */
  conversationId: string;
}

/** The RPC never returns these (see types.ts), but the correction API can
 *  still move an operation into one of them — defensive, not dead code. */
const TERMINAL_STATUSES: ReadonlyArray<string> = ["completed", "cancelled"];

type OpenFormKind = "operation" | "beneficiary" | "reassign" | "complete";

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
 *  chip always copies the raw, unformatted value. */
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
 *  destination amount — that's not shown anywhere in the header. */
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

/** A beneficiary's own `amount` when set; otherwise, only when it's the
 *  operation's single beneficiary, the operation's auto-calculated
 *  `quotedDestinationAmount` (migration 100). Multiple beneficiaries never
 *  fall back — an unset amount there is genuinely missing. */
function resolveBeneficiaryAmount(
  beneficiary: RemittanceBeneficiaryRead,
  operation: RemittanceOperationRead,
): number | null {
  if (beneficiary.amount !== null) return beneficiary.amount;
  return operation.beneficiaries.length === 1 ? operation.quotedDestinationAmount : null;
}

/** What the deposit block shows as the destination amount: the (single)
 *  vigente beneficiary's own amount (falling back to the operation's
 *  auto-calculated one, same as `resolveBeneficiaryAmount`), an
 *  "amount missing" state when that's null, or — for zero beneficiaries —
 *  the operation-level amount when known. Two or more beneficiaries never
 *  render here; each shows its own amount instead, in the beneficiary
 *  list below. */
function computeSummaryAmount(
  operation: RemittanceOperationRead,
  t: (key: string) => string,
): SummaryAmount | null {
  if (operation.beneficiaries.length === 1) {
    const beneficiary = operation.beneficiaries[0]!;
    const amount = resolveBeneficiaryAmount(beneficiary, operation);
    if (amount === null) return { kind: "missing" };
    const isZelle = beneficiary.beneficiaryType === "zelle";
    const currencyLabel = isZelle ? t("beneficiaryType.zelle") : (beneficiary.currency ?? operation.destinationCurrency);
    return { kind: "amount", display: money(amount, currencyLabel)! };
  }

  if (operation.beneficiaries.length === 0) {
    if (operation.quotedDestinationAmount === null) return null;
    const isZelle = operation.deliveryMethod === "zelle";
    const currencyLabel = isZelle ? t("beneficiaryType.zelle") : operation.destinationCurrency;
    return { kind: "amount", display: money(operation.quotedDestinationAmount, currencyLabel)! };
  }

  return null;
}

/** Whether the "Complete transfer" section shows the delivery-proof note
 *  field: only for Zelle, where the recipient's name is the one thing the
 *  screenshot itself never carries. Mirrors `destinationLabel`'s Zelle
 *  check (operation-level rail) plus the single-beneficiary case. */
function isZelleOperation(operation: RemittanceOperationRead): boolean {
  if (operation.deliveryMethod === "zelle") return true;
  return operation.beneficiaries.length === 1 && operation.beneficiaries[0]!.beneficiaryType === "zelle";
}

/**
 * Presentational: one open remesa operation. Header is minimal — the
 * source amount, an arrow, and the destination name (rail label,
 * destination currency, or delivery method), each with a lock indicator
 * when admin-locked; the destination amount is never rendered there. Below
 * the header, always visible, a status chip (dot + tone-colored label,
 * no pill) and (when present) a deposit method chip. When `expanded`
 * (owned by the panel container so only one card is open at a time): the
 * deposit review block — which, once verified, also shows the destination
 * amount computed by `computeSummaryAmount` (single beneficiary or none;
 * two or more never show a top row) — an edit-operation affordance +
 * correction form, and a "Deliver to" block listing every current
 * ('vigente') beneficiary as a name/action line (Zelle) or a slim action
 * line (every other type, which has no name), its own plain (non-copyable)
 * amount row when there are two or more beneficiaries, followed by a stack
 * of tap-to-copy chips (account, then card/phone). A `onCompleteTransfer`
 * button renders at the bottom once the operation is `ready_to_transfer`
 * and editable.
 */
export function RemittanceOperationCard({
  operation,
  canEdit,
  role,
  otherOpenOperations,
  onChanged,
  expanded,
  onToggle,
  conversationId,
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

  const showCompleteTransfer = operation.status === "ready_to_transfer" && editable;
  const summaryAmount = computeSummaryAmount(operation, t as (key: string) => string);

  const beneficiaryActions = (
    beneficiary: RemittanceOperationRead["beneficiaries"][number],
    hideEdit = false,
  ) =>
    editable && (
      <>
        {!hideEdit && (
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
        )}
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
      </>
    );

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
        <div className="mt-[22px] space-y-2.5">
          {openForm?.kind === "operation" && (
            <OperationCorrectionForm operation={operation} onDone={handleChanged} onCancel={() => setOpenForm(null)} />
          )}

          <DepositReviewContainer
            operationId={operation.id}
            canEdit={editable}
            role={role}
            onChanged={onChanged}
            summaryAmount={summaryAmount}
            onAddAmount={editable ? () => toggleForm({ kind: "operation" }) : undefined}
          />

          <div className="pt-3">
            <div className="flex min-h-6 items-center gap-1">
              <h4 className="flex flex-1 items-center gap-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
                {t("deliverTo")}
                {isLocked("beneficiaries") && <Lock size={12} aria-label={t("lockedByOperator")} />}
              </h4>
              {operation.beneficiaries.length === 1 &&
                beneficiaryActions(
                  operation.beneficiaries[0],
                  openForm?.kind === "beneficiary" && openForm.beneficiaryId === operation.beneficiaries[0]!.id,
                )}
            </div>
            {operation.beneficiaries.length === 0 ? (
              <p className="mt-1 text-xs text-muted-foreground">{t("noBeneficiaries")}</p>
            ) : (
              <ul className="mt-1.5 space-y-4">
                {operation.beneficiaries.map((beneficiary) => {
                  const isZelle = beneficiary.beneficiaryType === "zelle";
                  const amount = resolveBeneficiaryAmount(beneficiary, operation);
                  const currencyLabel = isZelle
                    ? t("beneficiaryType.zelle")
                    : (beneficiary.currency ?? operation.destinationCurrency);
                  const amountDisplay = amount === null ? null : money(amount, currencyLabel);

                  const isEditingBeneficiary =
                    openForm?.kind === "beneficiary" && openForm.beneficiaryId === beneficiary.id;
                  const isMovingBeneficiary =
                    openForm?.kind === "reassign" && openForm.beneficiaryId === beneficiary.id;

                  return (
                    <li key={beneficiary.id} className="space-y-1.5 text-xs">
                      {operation.beneficiaries.length >= 2 && editable && (
                        <div className="flex justify-end gap-1">
                          {beneficiaryActions(beneficiary, isEditingBeneficiary)}
                        </div>
                      )}

                      {isEditingBeneficiary ? (
                        <BeneficiaryEditFields
                          beneficiary={beneficiary}
                          amount={amount}
                          showAmountField={operation.beneficiaries.length >= 2 && amount !== null}
                          t={t as (key: string) => string}
                          onCancel={() => setOpenForm(null)}
                          onSaved={handleChanged}
                        />
                      ) : (
                        <div className="space-y-1.5">
                          {operation.beneficiaries.length >= 2 && amount !== null && (
                            <div className="flex items-center gap-2 text-sm leading-5">
                              <span className="flex w-4 shrink-0 items-center justify-center">
                                <Banknote className="size-3.5 text-muted-foreground" aria-hidden="true" />
                              </span>
                              <span className="font-medium tabular-nums">{amountDisplay}</span>
                            </div>
                          )}

                          {isZelle && (
                            beneficiary.name ? (
                              <CopyChip
                                value={beneficiary.name}
                                display={<span className="font-sans text-sm font-medium">{beneficiary.name}</span>}
                                icon={<UserRound className="size-3.5" aria-hidden="true" />}
                                ariaLabel={t("copyValue", { label: t("name") })}
                              />
                            ) : (
                              <p className="flex items-center gap-2 px-2 text-xs text-muted-foreground">
                                <UserRound className="size-3.5" aria-hidden="true" />
                                {t("beneficiaryNameUnavailable")}
                              </p>
                            )
                          )}
                          {isZelle && beneficiary.zelleAccount && (
                            <CopyChip
                              value={beneficiary.zelleAccount}
                              icon={<AtSign className="size-3.5" aria-hidden="true" />}
                              ariaLabel={t("copyValue", { label: t("zelleAccount") })}
                            />
                          )}
                          {!isZelle && beneficiary.cardNumber && (
                            <CopyChip
                              value={beneficiary.cardNumber}
                              display={formatCardNumber(beneficiary.cardNumber)}
                              icon={<CreditCard className="size-3.5" aria-hidden="true" />}
                              ariaLabel={t("copyValue", { label: t("card") })}
                            />
                          )}
                          {!isZelle && beneficiary.phone && (
                            <CopyChip
                              value={beneficiary.phone}
                              icon={<Phone className="size-3.5" aria-hidden="true" />}
                              ariaLabel={t("copyValue", { label: t("phone") })}
                            />
                          )}
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

          {showCompleteTransfer &&
            (openForm?.kind === "complete" ? (
              <CompleteTransferContainer
                operationId={operation.id}
                conversationId={conversationId}
                isZelle={isZelleOperation(operation)}
                onDone={handleChanged}
                onCancel={() => setOpenForm(null)}
              />
            ) : (
              <Button
                type="button"
                size="lg"
                className="w-full"
                onClick={() => toggleForm({ kind: "complete" })}
              >
                {t("completeTransfer.button")}
              </Button>
            ))}
        </div>
      )}
    </article>
  );
}

interface BeneficiaryEditFieldsProps {
  beneficiary: RemittanceBeneficiaryRead;
  /** The resolved amount shown by the read-only view (see
   *  `resolveBeneficiaryAmount`); only editable via `showAmountField`. */
  amount: number | null;
  /** Whether the read-only view was showing a per-beneficiary amount row
   *  (two or more beneficiaries, and `amount` is set) — the only case the
   *  amount becomes an input here. */
  showAmountField: boolean;
  t: (key: string) => string;
  onCancel: () => void;
  onSaved: () => void;
}

/**
 * Replaces one beneficiary's data chips in place with editable inputs
 * (same icons, same visual slot), plus a right-aligned Cancel/Save row.
 * Zelle edits name + Zelle account; every other type edits card + phone.
 * Beneficiary type, delivery method and currency are not editable here —
 * that stays on the (now-removed) stacked correction form's territory.
 */
function BeneficiaryEditFields({ beneficiary, amount, showAmountField, t, onCancel, onSaved }: BeneficiaryEditFieldsProps) {
  const isZelle = beneficiary.beneficiaryType === "zelle";
  const initialName = beneficiary.name ?? "";
  const initialZelleAccount = beneficiary.zelleAccount ?? "";
  const initialCardDigits = (beneficiary.cardNumber ?? "").replace(/\D/g, "");
  const initialPhoneDigits = (beneficiary.phone ?? "").replace(/\D/g, "");
  const initialAmount = amount === null ? "" : String(amount);

  const [name, setName] = useState(initialName);
  const [zelleAccount, setZelleAccount] = useState(initialZelleAccount);
  const [cardNumber, setCardNumber] = useState(beneficiary.cardNumber ?? "");
  const [phone, setPhone] = useState(beneficiary.phone ?? "");
  const [amountValue, setAmountValue] = useState(initialAmount);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSave() {
    setError(null);
    const changes: Record<string, unknown> = {};

    if (isZelle) {
      const trimmedName = name.trim();
      if (trimmedName !== initialName) {
        if (initialName !== "" && trimmedName === "") {
          setError(t("cannotBeEmpty"));
          return;
        }
        if (trimmedName !== "") changes.name = trimmedName;
      }

      const trimmedZelleAccount = zelleAccount.trim();
      if (trimmedZelleAccount !== initialZelleAccount) {
        if (initialZelleAccount !== "" && trimmedZelleAccount === "") {
          setError(t("cannotBeEmpty"));
          return;
        }
        if (trimmedZelleAccount !== "") changes.zelle_account = trimmedZelleAccount;
      }
    } else {
      const digitsCard = cardNumber.replace(/\D/g, "");
      if (digitsCard !== initialCardDigits) {
        if (digitsCard === "" && initialCardDigits !== "") {
          setError(t("cannotBeEmpty"));
          return;
        }
        if (digitsCard !== "") {
          if (!CARD_NUMBER_PATTERN.test(digitsCard)) {
            setError(t("invalidCard"));
            return;
          }
          changes.card_number = digitsCard;
        }
      }

      const digitsPhone = phone.replace(/\D/g, "");
      if (digitsPhone !== initialPhoneDigits) {
        if (digitsPhone === "" && initialPhoneDigits !== "") {
          setError(t("cannotBeEmpty"));
          return;
        }
        if (digitsPhone !== "") {
          if (!PHONE_PATTERN.test(digitsPhone)) {
            setError(t("invalidPhone"));
            return;
          }
          changes.phone = digitsPhone;
        }
      }
    }

    if (showAmountField) {
      const trimmedAmount = amountValue.trim();
      if (trimmedAmount !== initialAmount) {
        const parsed = Number(trimmedAmount);
        if (!(parsed > 0)) {
          setError(t("invalidAmount"));
          return;
        }
        changes.amount = parsed;
      }
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

  return (
    <div className="space-y-1.5" onKeyDown={handleKeyDown}>
      {showAmountField && (
        <InlineEditField
          id={`inline-amount-${beneficiary.id}`}
          icon={<Banknote className="size-3.5" aria-hidden="true" />}
          value={amountValue}
          onChange={setAmountValue}
          placeholder={t("amount")}
          ariaLabel={t("amount")}
          disabled={pending}
          inputMode="decimal"
          autoFocus
        />
      )}

      {isZelle ? (
        <>
          <InlineEditField
            id={`inline-name-${beneficiary.id}`}
            icon={<UserRound className="size-3.5" aria-hidden="true" />}
            value={name}
            onChange={setName}
            placeholder={t("name")}
            ariaLabel={t("name")}
            disabled={pending}
            variant="name"
            autoFocus={!showAmountField}
          />
          <InlineEditField
            id={`inline-zelle-account-${beneficiary.id}`}
            icon={<AtSign className="size-3.5" aria-hidden="true" />}
            value={zelleAccount}
            onChange={setZelleAccount}
            placeholder={t("zelleAccount")}
            ariaLabel={t("zelleAccount")}
            disabled={pending}
          />
        </>
      ) : (
        <>
          <InlineEditField
            id={`inline-card-${beneficiary.id}`}
            icon={<CreditCard className="size-3.5" aria-hidden="true" />}
            value={cardNumber}
            onChange={setCardNumber}
            placeholder={t("card")}
            ariaLabel={t("card")}
            disabled={pending}
            inputMode="numeric"
            autoFocus={!showAmountField}
          />
          <InlineEditField
            id={`inline-phone-${beneficiary.id}`}
            icon={<Phone className="size-3.5" aria-hidden="true" />}
            value={phone}
            onChange={setPhone}
            placeholder={t("phone")}
            ariaLabel={t("phone")}
            disabled={pending}
            inputMode="numeric"
          />
        </>
      )}

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
