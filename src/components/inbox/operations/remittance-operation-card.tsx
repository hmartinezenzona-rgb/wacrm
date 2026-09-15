"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { ArrowRightLeft, AtSign, ChevronDown, CreditCard, Lock, Pencil, Phone, Users } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { AccountRole } from "@/lib/auth/roles";
import type {
  AmountOrigin,
  RemittanceBeneficiaryRead,
  RemittanceOperationRead,
} from "@/lib/remittance-operations/types";
import { OperationCorrectionForm } from "./operation-correction-form";
import { BeneficiaryCorrectionForm } from "./beneficiary-correction-form";
import { BeneficiaryReassignControl } from "./beneficiary-reassign-control";
import { CopyChip } from "./copy-chip";
import { DepositReviewContainer } from "./deposit-review-container";
import { KNOWN_BENEFICIARY_TYPES, MethodIcon, StatusChip } from "./operation-icons";

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
  /** When given, and the operation is `ready_to_transfer` and editable, a
   *  full-width "Complete transfer" button renders at the bottom of the
   *  expanded card. Nobody passes this yet — it's wired in a later slice. */
  onCompleteTransfer?: () => void;
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

function resolveAmountOrigin(
  beneficiary: RemittanceBeneficiaryRead,
  operation: RemittanceOperationRead,
): AmountOrigin | null {
  return beneficiary.amountOrigin ?? operation.quotedDestinationOrigin;
}

/** CUP amounts are derived by multiplying the source amount by the rate;
 *  every other destination (USD, Zelle) divides — see the "calculated"
 *  hint copy under the amount chip. */
function calculatedHintKey(currencyLabel: string | null): "calculatedDivide" | "calculatedMultiply" {
  return currencyLabel === "CUP" ? "calculatedMultiply" : "calculatedDivide";
}

/**
 * Presentational: one open remesa operation. Header is minimal — the
 * source amount, an arrow, and the destination name (rail label,
 * destination currency, or delivery method), each with a lock indicator
 * when admin-locked; the destination amount is never rendered there. Below
 * the header, always visible, a status chip and (when present) a deposit
 * method chip. When `expanded` (owned by the panel container so only one
 * card is open at a time): the deposit review block, an edit-operation
 * affordance + correction form, and a "Deliver to" block listing every
 * current ('vigente') beneficiary as a name/action line (Zelle) or a slim
 * action line (every other type, which has no name) followed by a stack of
 * tap-to-copy chips (amount, then account or card/phone). A
 * `onCompleteTransfer` button renders at the bottom once the operation is
 * `ready_to_transfer` and editable.
 */
export function RemittanceOperationCard({
  operation,
  canEdit,
  role,
  otherOpenOperations,
  onChanged,
  expanded,
  onToggle,
  onCompleteTransfer,
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
  const amountLocked = isLocked("quoted_destination_amount") || isLocked("beneficiaries");

  const showCompleteTransfer = Boolean(onCompleteTransfer) && operation.status === "ready_to_transfer" && editable;

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

          <DepositReviewContainer operationId={operation.id} canEdit={editable} role={role} onChanged={onChanged} />

          <div>
            <h4 className="flex items-center gap-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
              {t("deliverTo")}
              {isLocked("beneficiaries") && <Lock size={12} aria-label={t("lockedByOperator")} />}
            </h4>
            {operation.beneficiaries.length === 0 ? (
              <p className="mt-1 text-xs text-muted-foreground">{t("noBeneficiaries")}</p>
            ) : (
              <ul className="mt-1.5 space-y-4">
                {operation.beneficiaries.map((beneficiary) => {
                  const isZelle = beneficiary.beneficiaryType === "zelle";
                  const amount = resolveBeneficiaryAmount(beneficiary, operation);
                  const origin = resolveAmountOrigin(beneficiary, operation);
                  const currencyLabel = isZelle
                    ? t("beneficiaryType.zelle")
                    : (beneficiary.currency ?? operation.destinationCurrency);
                  const amountDisplay = amount === null ? null : money(amount, currencyLabel);
                  const showLockHint = origin === "manual" || amountLocked;
                  const rate = operation.quotedDestinationRate;
                  const showCalculatedHint = !showLockHint && origin === "calculated" && rate !== null;

                  const isEditingBeneficiary =
                    openForm?.kind === "beneficiary" && openForm.beneficiaryId === beneficiary.id;
                  const isMovingBeneficiary =
                    openForm?.kind === "reassign" && openForm.beneficiaryId === beneficiary.id;

                  const actions = editable && (
                    <>
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
                    </>
                  );

                  return (
                    <li key={beneficiary.id} className="space-y-1.5 text-xs">
                      {isZelle ? (
                        <div className="flex items-center gap-1">
                          <span className="min-w-0 flex-1 truncate text-sm font-medium text-foreground">
                            {beneficiary.name ?? t("beneficiaryNameUnavailable")}
                          </span>
                          {actions}
                        </div>
                      ) : (
                        editable && <div className="flex justify-end gap-1">{actions}</div>
                      )}

                      <div className="space-y-1.5">
                        {amount === null ? (
                          <CopyChip
                            value=""
                            display={t("amountMissing")}
                            ariaLabel={t("amountMissing")}
                            tone="warning"
                            disabled={!editable}
                            onActivate={editable ? () => toggleForm({ kind: "operation" }) : undefined}
                          />
                        ) : (
                          <CopyChip
                            value={String(amount)}
                            display={amountDisplay}
                            ariaLabel={t("copyValue", { label: t("amount") })}
                            hint={
                              showLockHint ? (
                                <Lock className="size-3" aria-label={t("manualAmount")} />
                              ) : showCalculatedHint ? (
                                t(calculatedHintKey(currencyLabel), { rate })
                              ) : undefined
                            }
                          />
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

          {showCompleteTransfer && (
            <Button type="button" size="lg" className="w-full" onClick={onCompleteTransfer}>
              {t("completeTransfer")}
            </Button>
          )}
        </div>
      )}
    </article>
  );
}
