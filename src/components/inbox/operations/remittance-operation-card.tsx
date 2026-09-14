"use client";

import { useState, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import {
  ArrowRightLeft,
  AtSign,
  ChevronDown,
  ChevronRight,
  Coins,
  CreditCard,
  Lock,
  Pencil,
  Phone,
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
  /** Whether this card's details (chips + beneficiaries) are shown. The
   *  panel is an accordion — expansion is owned by the container, not
   *  local state, so only one card is open at a time. */
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

/**
 * Presentational: one open remesa operation, amount(s), delivery method,
 * status, every current ('vigente') beneficiary with its full (unmasked)
 * card/phone/name plus a copy button, admin-lock indicators, and — when
 * `canEdit` and the operation isn't terminal — inline correction and
 * reassignment affordances (Slice 6). Methods, statuses, and beneficiary
 * types render as icons plus human labels instead of raw enum values;
 * edit/move affordances are icon-only buttons. Cuba beneficiary types
 * (every type except "zelle") have no name, only card + phone; "zelle"
 * always has a name + Zelle account and no card/phone.
 *
 * Collapsible: the header (amount + status) is always visible; chips and
 * beneficiaries only render when `expanded` (owned by the panel container
 * so only one card is open at a time).
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
      icon: <MethodIcon method={value} label={t("deliveryMethod")} />,
      text: value ? methodLabel(value) : "—",
    });
  }

  if (operation.depositMethod !== null || isLocked("deposit_method")) {
    const value = operation.depositMethod;
    chips.push({
      key: "deposit",
      fieldKey: "deposit_method",
      label: t("depositMethod"),
      icon: <MethodIcon method={value} label={t("depositMethod")} />,
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

  const firstBeneficiary = operation.beneficiaries[0];

  return (
    <article className="rounded-lg border border-border bg-card p-2.5">
      <div className="flex items-start gap-1.5">
        <button
          type="button"
          aria-expanded={expanded}
          onClick={onToggle}
          className="flex min-w-0 flex-1 items-start gap-1.5 rounded-md text-left outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          {expanded ? (
            <ChevronDown className="mt-0.5 size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
          ) : (
            <ChevronRight className="mt-0.5 size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
          )}
          <span className="min-w-0 flex-1 space-y-1">
            <span className="flex flex-wrap items-center gap-x-1 text-sm font-semibold tabular-nums text-foreground">
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
            </span>
            <span className="flex flex-wrap items-center gap-1.5">
              <StatusChip status={operation.status} label={t(`status.${operation.status}`)} />
              {!expanded && firstBeneficiary && (
                <span
                  className="inline-flex items-center gap-1 text-xs text-muted-foreground"
                  title={t("beneficiaries")}
                >
                  <MethodIcon
                    method={firstBeneficiary.beneficiaryType}
                    label={t(`beneficiaryType.${firstBeneficiary.beneficiaryType}`)}
                  />
                  <Users className="size-3.5" aria-hidden="true" />
                  {operation.beneficiaries.length}
                </span>
              )}
            </span>
          </span>
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

      {expanded && (
        <div className="mt-2.5 space-y-2.5">
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
                  const isZelle = beneficiary.beneficiaryType === "zelle";
                  const isEditingBeneficiary =
                    openForm?.kind === "beneficiary" && openForm.beneficiaryId === beneficiary.id;
                  const isMovingBeneficiary =
                    openForm?.kind === "reassign" && openForm.beneficiaryId === beneficiary.id;

                  return (
                    <li key={beneficiary.id} className="space-y-1 rounded-md bg-muted/60 p-2 text-xs">
                      <div className="flex items-center gap-2">
                        <MethodIcon
                          method={beneficiary.beneficiaryType}
                          label={t(`beneficiaryType.${beneficiary.beneficiaryType}`)}
                        />
                        {isZelle ? (
                          <span className="flex min-w-0 flex-1 items-center gap-1">
                            <span className="truncate text-sm font-medium text-foreground">
                              {beneficiary.name ?? t("beneficiaryNameUnavailable")}
                            </span>
                            {beneficiary.name && (
                              <CopyButton value={beneficiary.name} ariaLabel={`${t("copy")} ${t("name")}`} />
                            )}
                          </span>
                        ) : (
                          <span className="flex-1" />
                        )}
                        {beneficiaryAmount && (
                          <span className="shrink-0 font-semibold tabular-nums text-foreground">
                            {beneficiaryAmount}
                          </span>
                        )}
                        {editable && (
                          <div className="flex shrink-0 gap-0.5">
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
                      </div>

                      {!isZelle && beneficiary.cardNumber && (
                        <DataRow
                          icon={<CreditCard className="size-3.5" aria-hidden="true" />}
                          label={t("card")}
                          display={formatCardNumber(beneficiary.cardNumber)}
                          value={beneficiary.cardNumber}
                          copyLabel={`${t("copy")} ${t("card")}`}
                          numeric
                        />
                      )}
                      {!isZelle && beneficiary.phone && (
                        <DataRow
                          icon={<Phone className="size-3.5" aria-hidden="true" />}
                          label={t("phone")}
                          display={beneficiary.phone}
                          value={beneficiary.phone}
                          copyLabel={`${t("copy")} ${t("phone")}`}
                          numeric
                        />
                      )}
                      {isZelle && beneficiary.zelleAccount && (
                        <DataRow
                          icon={<AtSign className="size-3.5" aria-hidden="true" />}
                          label={t("zelleAccount")}
                          display={beneficiary.zelleAccount}
                          value={beneficiary.zelleAccount}
                          copyLabel={`${t("copy")} ${t("zelleAccount")}`}
                        />
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

/** One copyable beneficiary field: the field icon flush left (same column
 *  as the beneficiary type badge), the value flush right with its copy
 *  button at the edge. */
function DataRow({
  icon,
  label,
  display,
  value,
  copyLabel,
  numeric = false,
}: {
  icon: ReactNode;
  label: string;
  display: string;
  value: string;
  copyLabel: string;
  numeric?: boolean;
}) {
  return (
    <div className="flex items-center gap-2">
      <span className="flex w-5 shrink-0 justify-center text-muted-foreground" title={label}>
        {icon}
      </span>
      <span className="sr-only">{label}: </span>
      <span
        className={`ml-auto min-w-0 break-all text-right font-medium text-foreground ${numeric ? "tabular-nums" : ""}`}
      >
        {display}
      </span>
      <CopyButton value={value} ariaLabel={copyLabel} />
    </div>
  );
}
