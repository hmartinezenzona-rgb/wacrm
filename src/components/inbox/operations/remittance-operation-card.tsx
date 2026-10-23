"use client";

import { useState, type KeyboardEvent } from "react";
import { useTranslations } from "next-intl";
import { useServiceName } from "@/hooks/use-service-name";
import { ArrowRightLeft, AtSign, Banknote, Building2, ChevronDown, CreditCard, Landmark, Lock, MapPin, Pencil, Phone, Split, Trash2, UserPlus, UserRound, Users } from "lucide-react";
import { Button } from "@/components/ui/button";
import { canForceVerify, type AccountRole } from "@/lib/auth/roles";
import { corregirBeneficiario } from "@/lib/remittance-operations/commands";
import { effectiveStatus } from "@/lib/remittance-operations/effective-status";
import { buildMexicoBeneficiaryChanges, isMexicoBeneficiaryType } from "@/lib/remittance-operations/mexico";
import { SALDO_UNIT_CUP, currentServiceOf, saldoPackages } from "@/lib/remittance-operations/services";
import type {
  ConversationQuoteRead,
  OperationDeliveryMode,
  OperationReceiptsRead,
  RemittanceBeneficiaryRead,
  RemittanceOperationRead,
} from "@/lib/remittance-operations/types";
import { OperationCorrectionForm } from "./operation-correction-form";
import { BeneficiaryAddControl } from "./beneficiary-add-control";
import { BeneficiaryIdPhoto, IdPhotoFormRow } from "./beneficiary-id-photo";
import { BeneficiaryReassignControl } from "./beneficiary-reassign-control";
import { ComboBeneficiaryEditFields } from "./combo-beneficiary-edit-fields";
import { ComboCostField } from "./combo-cost-field";
import { CompleteTransferContainer } from "./complete-transfer-container";
import { CupPlanBlock } from "./cup-plan-block";
import { CopyChip } from "./copy-chip";
import { MexicoRecipientRows } from "./mexico-recipient-rows";
import { DepositReviewContainer } from "./deposit-review-container";
import type { SummaryAmount } from "./deposit-review-section";
import { ConfirmCancelButtons } from "./confirm-cancel-buttons";
import { InlineEditField } from "./inline-edit-field";
import { OperationClosingControl } from "./operation-closing-control";
import { SplitDepositForm } from "./split-deposit-form";
import { KNOWN_BENEFICIARY_TYPES, StatusChip } from "./operation-icons";
import { formatNumber } from "@/lib/format-number";

const CARD_NUMBER_PATTERN = /^\d{16}$/;
const PHONE_PATTERN = /^\d{8,15}$/;
const RECHARGE_PHONE_PATTERN = /^[56]\d{7}$/;

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
  /** Role that decides who sees the combo cost field; defaults to `role`. The panel
   *  hands history cards `role={null}` (no actions) but still passes the real role
   *  here, since a completed combo with no cost is exactly what needs one. */
  costRole?: AccountRole | null;
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
  /** Bumped by the panel container after a silent refetch (realtime
   *  `deals` change, or another card's `onChanged`) — forwarded to
   *  `DepositReviewContainer` so it silently refetches its own receipts
   *  too, without a loading flash. */
  refreshToken?: number;
  /** This operation's receipts, prefetched by the panel container's own
   *  request (panel-26's `receiptsByOperationId`) — forwarded straight
   *  through to `DepositReviewContainer` as `initialData` so the deposit
   *  block paints in the same round trip. `undefined` when the prefetch
   *  failed for this operation or wasn't composed; the container falls
   *  back to fetching it itself. */
  initialReceipts?: OperationReceiptsRead;
  /** What the bot quoted for the conversation, shown as one read-only line
   *  before any deposit. The container hands it to a single open card;
   *  never rendered on a history operation. */
  quote?: ConversationQuoteRead | null;
  /** The operations sharing this one's deposit (a mixed send), for the split editor; the operation alone when omitted. */
  mixedMembers?: RemittanceOperationRead[];
}

/** The RPC never returns these (see types.ts), but the correction API can
 *  still move an operation into one of them — defensive, not dead code. */
const TERMINAL_STATUSES: ReadonlyArray<string> = ["completed", "cancelled"];

/** Statuses a remesa can no longer be deleted from: finished, or already
 *  verified (money moved) — mirrors `crm_eliminar_operacion` (migration 190). */
const NOT_DELETABLE_STATUSES: ReadonlyArray<string> = ["completed", "cancelled", "ready_to_transfer", "transferring"];

/** Statuses a verified remesa can be closed manually from
 *  (`crm_cerrar_operacion_manual`, migration 190). */
const MANUALLY_CLOSABLE_STATUSES: ReadonlyArray<string> = ["ready_to_transfer", "transferring"];

type OpenFormKind = "operation" | "beneficiary" | "reassign" | "complete" | "addBeneficiary" | "close" | "delete" | "split";

interface OpenFormState {
  kind: OpenFormKind;
  beneficiaryId?: string;
}

function money(amount: number | null, currency: string | null): string | null {
  if (amount === null) return null;
  const formatted = formatNumber(amount);
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

/** Name of a service key (the shared canonical names); an unknown key prints as it is. */
type ServiceNameOf = (key: string) => string;

/** Human label for a known beneficiary/delivery type, the deposit method
 *  "mmg" special case, or the raw value as a last resort. */
function knownMethodLabel(method: string, t: (key: string) => string, name: ServiceNameOf): string {
  return KNOWN_BENEFICIARY_TYPES.includes(method)
    ? name(method)
    : method === "mmg"
      ? t("depositMethodValue.mmg")
      : method;
}

/** What the header shows to the right of the arrow: "Mixed" as soon as the
 *  beneficiaries land on more than one unit (a CUP + Zelle split has no single
 *  destination to name), otherwise the delivery method's human label for the
 *  fixed Zelle/Clásica/Tropical rails, otherwise the destination currency
 *  (operation-level, then the first beneficiary's), otherwise the delivery
 *  method's label as a last resort. Never the destination amount — that's not
 *  shown anywhere in the header. */
function destinationLabel(
  operation: RemittanceOperationRead,
  t: (key: string, params?: Record<string, unknown>) => string,
  name: ServiceNameOf,
): string | null {
  const { deliveryMethod, destinationCurrency, beneficiaries } = operation;
  if (isRecharge(operation)) return name("recarga");
  if (isCombo(operation)) return name("combo");
  // A visa shows how many extensions from the start (owner test 2026-10-04): the count used to appear only once the
  // deposit was verified.
  if (isVisa(operation)) return `${name("visa")} · ${visaCountLabel(operation, t)}`;
  // A mobile balance names its packages (and the saldo they carry) once the deposit is a whole number of them.
  if (isSaldo(operation)) {
    const label = saldoSummaryLabel(operation, t);
    return label ? `${name("saldo")} · ${label}` : name("saldo");
  }

  const units = new Set(
    beneficiaries
      .map((b) => unitLabel(b.beneficiaryType, b.currency ?? destinationCurrency, name))
      .filter((unit): unit is string => unit !== null),
  );
  if (units.size > 1) return name("mixed");
  if (units.size === 1) return [...units][0]!;

  if (deliveryMethod === "zelle" || deliveryMethod === "clasica" || deliveryMethod === "tropical") {
    return name(deliveryMethod);
  }
  if (destinationCurrency) return destinationCurrency;
  if (deliveryMethod) return knownMethodLabel(deliveryMethod, t, name);
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
/** Services whose amount reads as the service itself ("100 Zelle", "40
 *  Clásica") instead of a currency code — the unit the operator and the
 *  client talk in. Everything else shows its currency. */
const SERVICE_UNIT_TYPES: ReadonlyArray<string> = ["zelle", "clasica", "tropical"];

function unitLabel(
  service: string | null,
  currency: string | null,
  name: ServiceNameOf,
): string | null {
  if (service && SERVICE_UNIT_TYPES.includes(service)) return name(service);
  if (service === "efectivo_usd") return name(service);
  return currency;
}

function isRecharge(operation: RemittanceOperationRead): boolean {
  return operation.serviceType === "recarga";
}

function isCombo(operation: RemittanceOperationRead): boolean {
  return operation.serviceType === "combo";
}

function isVisa(operation: RemittanceOperationRead): boolean {
  return operation.serviceType === "visa";
}

function isSaldo(operation: RemittanceOperationRead): boolean {
  return operation.serviceType === "saldo";
}

/** A recharge and a mobile balance take phone-only recipients, never a card or an amount per recipient. */
function isPhoneOnly(operation: RemittanceOperationRead): boolean {
  return isRecharge(operation) || isSaldo(operation);
}

/** "N package(s) · M CUP": the packages in the deposit (saldoPackages) and the saldo they carry (SALDO_UNIT_CUP each).
 *  `null` when the deposit is not a whole number of packages: nothing is rounded, the line waits for a person. */
function saldoSummaryLabel(
  operation: RemittanceOperationRead,
  t: (key: string, params?: Record<string, unknown>) => string,
): string | null {
  const count = saldoPackages(operation.quotedSourceAmount);
  if (count === null) return null;
  return t(count === 1 ? "saldoCountOne" : "saldoCountMany", { count, saldo: formatNumber(count * SALDO_UNIT_CUP) });
}

/** Price of one visa extension in GYD (migration 213): the operation's amount is this times the people. */
const VISA_PRICE_GYD = 5000;

/** "N extension(s)": a visa's amount is VISA_PRICE_GYD per person, at least one. */
function visaCountLabel(
  operation: RemittanceOperationRead,
  t: (key: string, params?: Record<string, unknown>) => string,
): string {
  const count = Math.max(1, Math.round((operation.quotedSourceAmount ?? 0) / VISA_PRICE_GYD));
  return t(count === 1 ? "visaCountOne" : "visaCountMany", { count });
}

function computeSummaryAmount(
  operation: RemittanceOperationRead,
  t: (key: string, params?: Record<string, unknown>) => string,
  name: ServiceNameOf,
): SummaryAmount | null {
  // A recharge is counted, not priced here: one number per recharge.
  if (isRecharge(operation)) {
    const count = operation.beneficiaries.filter((b) => b.beneficiaryType === "recarga").length;
    if (count === 0) return null;
    return { kind: "amount", display: t(count === 1 ? "rechargeCountOne" : "rechargeCountMany", { count }) };
  }

  // A mobile balance shows its packages and the saldo they carry; its one recipient is a phone.
  if (isSaldo(operation)) {
    const label = saldoSummaryLabel(operation, t);
    return label ? { kind: "amount", display: label } : null;
  }

  // A combo is counted too: each recipient's own GYD amount shows on its row.
  if (isCombo(operation)) {
    const count = operation.beneficiaries.filter((b) => b.beneficiaryType === "combo").length;
    if (count === 0) return null;
    return { kind: "amount", display: t(count === 1 ? "comboCountOne" : "comboCountMany", { count }) };
  }

  // A visa has no recipients: the extensions are counted from the amount.
  if (isVisa(operation)) {
    return { kind: "amount", display: visaCountLabel(operation, t) };
  }

  if (operation.beneficiaries.length === 1) {
    const beneficiary = operation.beneficiaries[0]!;
    const amount = resolveBeneficiaryAmount(beneficiary, operation);
    if (amount === null) return { kind: "missing" };
    const currencyLabel = unitLabel(
      beneficiary.beneficiaryType,
      beneficiary.currency ?? operation.destinationCurrency,
      name,
    );
    return { kind: "amount", display: money(amount, currencyLabel)! };
  }

  if (operation.beneficiaries.length === 0) {
    if (operation.quotedDestinationAmount === null) return null;
    const currencyLabel = unitLabel(operation.deliveryMethod, operation.destinationCurrency, name);
    return { kind: "amount", display: money(operation.quotedDestinationAmount, currencyLabel)! };
  }

  return null;
}

/** Whether the "Complete transfer" section shows the delivery-proof note
 *  field: whenever the operation has at least one current Zelle
 *  beneficiary, where the recipient's name is the one thing the
 *  screenshot itself never carries — regardless of beneficiary count. Once
 *  beneficiaries exist, `delivery_method` is ignored: it's set only by the
 *  legacy notes trigger with an arbitrary `LIMIT 1` and is never touched by
 *  the reparto/add-beneficiary RPCs, so it can be stale or null even for a
 *  live Zelle operation, and mustn't hide the caption for a mixed reparto,
 *  nor show it for a pure Cuban-card one. `delivery_method` is the only
 *  signal left for the legacy shape: an operation with no beneficiaries
 *  yet. */
function isZelleOperation(operation: RemittanceOperationRead): boolean {
  if (operation.beneficiaries.length > 0) {
    return operation.beneficiaries.some((beneficiary) => beneficiary.beneficiaryType === "zelle");
  }
  return operation.deliveryMethod === "zelle";
}

/** Short, locale-aware date + time for the history card's "Completed …"
 *  line — deliberately NOT pinned to "en-US" like `money()`: this is a
 *  timestamp for the viewing operator, not a financial figure that must
 *  read identically for everyone. */
function formatCompletedAt(iso: string | null): string {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date);
}

/** `history.proofSent`/`noProof`/`skipProof`/`closedManually` — only these
 *  delivery modes get a suffix; `legacy_pipeline` (and any future value) shows the
 *  completed date alone. */
const DELIVERY_MODE_HISTORY_KEY: Partial<Record<OperationDeliveryMode, string>> = {
  proof_sent: "history.proofSent",
  no_proof: "history.noProof",
  skip_proof: "history.skipProof",
  closed_manually: "history.closedManually",
};

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
  costRole,
  otherOpenOperations,
  onChanged,
  expanded,
  onToggle,
  conversationId,
  refreshToken,
  initialReceipts,
  quote,
  mixedMembers,
}: RemittanceOperationCardProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const serviceName = useServiceName();
  const [openForm, setOpenForm] = useState<OpenFormState | null>(null);

  // A history row is always read-only, on top of (and regardless of) the
  // terminal-status check below — see the type's `isHistory` doc comment.
  const editable = canEdit && !operation.isHistory && !TERMINAL_STATUSES.includes(operation.status);
  const isLocked = (key: string) => key in operation.adminLockedFields;
  const status = effectiveStatus(operation);

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
  const destLabel = destinationLabel(operation, t as (key: string, params?: Record<string, unknown>) => string, serviceName);
  const destLocked = isLocked("delivery_method") || isLocked("destination_currency") || isLocked("quoted_destination_amount");

  const methodLabel = (method: string): string => knownMethodLabel(method, t as (key: string) => string, serviceName);

  const lock = <Lock className="size-3 shrink-0" aria-label={t("lockedByOperator")} />;

  // Owner/admin only. The raw status (not the effective one) decides, since
  // that is what the RPCs check.
  const isManager = role !== null && canForceVerify(role);
  const effectiveCostRole = costRole === undefined ? role : costRole;
  const canSetComboCost = isCombo(operation) && effectiveCostRole !== null && canForceVerify(effectiveCostRole);
  const canDelete = isManager && !operation.isHistory && !NOT_DELETABLE_STATUSES.includes(operation.status);
  const canCloseManually =
    isManager && !operation.isHistory && MANUALLY_CLOSABLE_STATUSES.includes(operation.status);

  const showCompleteTransfer = status === "ready_to_transfer" && editable;
  const summaryAmount = computeSummaryAmount(operation, t as (key: string, params?: Record<string, unknown>) => string, serviceName);

  const beneficiaryActions = (
    beneficiary: RemittanceOperationRead["beneficiaries"][number],
    hideEdit = false,
  ) =>
    editable &&
    (
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
    <article
      className={`rounded-xl border px-2 py-2.5 ${operation.isHistory ? "border-border bg-muted/50 opacity-85" : "bg-card"} ${expanded ? "border-primary/40 shadow-[0_1px_3px_rgba(15,38,34,0.08)]" : operation.isHistory ? "" : "border-border"}`}
    >
      {expanded && (canDelete || editable) && (
        <div className="mb-1 flex items-center justify-end gap-1">
          {canDelete && (
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label={t("closing.deleteButton")}
              title={t("closing.deleteButton")}
              onClick={() => toggleForm({ kind: "delete" })}
            >
              <Trash2 aria-hidden="true" />
            </Button>
          )}
          {editable && (
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label={t("splitDeposit.button")}
              title={t("splitDeposit.button")}
              onClick={() => toggleForm({ kind: "split" })}
            >
              <Split aria-hidden="true" />
            </Button>
          )}
          {editable && (
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
      )}
      <div className={`rounded-lg ${expanded ? "bg-primary-soft/40 px-2 py-1.5" : ""}`}>
      <div className="flex items-center gap-1">
        <button
          type="button"
          aria-expanded={expanded}
          onClick={onToggle}
          className="flex min-w-0 flex-1 items-center gap-2 rounded-md text-left outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          <span className="flex min-w-0 flex-1 flex-wrap items-center gap-x-1 font-heading text-[15px] font-bold tabular-nums text-foreground">
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
      </div>

      <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
        <StatusChip status={status} label={t(`status.${status}`)} />
        {(operation.depositMethod !== null || isLocked("deposit_method")) && (
          <span className="inline-flex items-center gap-1 text-xs text-muted-foreground" title={t("depositMethod")}>
            <span aria-hidden="true">·</span>
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

      {quote && !operation.isHistory && !isRecharge(operation) && !isSaldo(operation) && !isCombo(operation) && !isVisa(operation) && (
        <p className="mt-1 text-[11px] tabular-nums text-muted-foreground">
          {quote.destinationAmount !== null && quote.destinationCurrency !== null
            ? t("quotedTo", {
                source: money(quote.gyd, "GYD")!,
                destination: money(quote.destinationAmount, quote.destinationCurrency)!,
              })
            : t("quoted", { source: money(quote.gyd, "GYD")! })}
        </p>
      )}

      {operation.isHistory && (
        <p className="mt-1 text-[11px] text-muted-foreground">
          {t("history.completedAt", { date: formatCompletedAt(operation.deliveredAt ?? operation.completedAt) })}
          {operation.deliveryMode &&
            DELIVERY_MODE_HISTORY_KEY[operation.deliveryMode] &&
            ` · ${t(DELIVERY_MODE_HISTORY_KEY[operation.deliveryMode]!)}`}
        </p>
      )}
      </div>

      {expanded && (
        <div className="mt-3 space-y-2.5">
          {openForm?.kind === "operation" && (
            <OperationCorrectionForm operation={operation} onDone={handleChanged} onCancel={() => setOpenForm(null)} />
          )}

          {openForm?.kind === "split" && (
            <SplitDepositForm
              operationId={operation.id}
              members={mixedMembers ?? [operation]}
              onDone={handleChanged}
              onCancel={() => setOpenForm(null)}
            />
          )}

          {openForm?.kind === "delete" && (
            <OperationClosingControl
              operationId={operation.id}
              kind="delete"
              onDone={handleChanged}
              onCancel={() => setOpenForm(null)}
            />
          )}

          <DepositReviewContainer
            operationId={operation.id}
            canEdit={editable}
            role={operation.isHistory ? null : role}
            onChanged={onChanged}
            summaryAmount={summaryAmount}
            onAddAmount={editable ? () => toggleForm({ kind: "operation" }) : undefined}
            refreshToken={refreshToken}
            initialData={initialReceipts}
          />

          {!isVisa(operation) && (
          <div className="border-t border-border pt-2.5">
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
              {editable && openForm?.kind !== "addBeneficiary" && !(isSaldo(operation) && operation.beneficiaries.length >= 1) &&
                !operation.beneficiaries.some((b) => b.beneficiaryType === "efectivo_usd") && (
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-xs"
                  aria-label={t("addBeneficiary")}
                  title={t("addBeneficiary")}
                  onClick={() => toggleForm({ kind: "addBeneficiary" })}
                >
                  <UserPlus aria-hidden="true" />
                </Button>
              )}
            </div>
            {openForm?.kind === "addBeneficiary" && (
              <div className="mt-1.5">
                <BeneficiaryAddControl
                  operationId={operation.id}
                  conversationId={conversationId}
                  serviceType={operation.serviceType}
                  service={currentServiceOf(operation)}
                  quote={
                    operation.beneficiaries.length === 0 &&
                    operation.quotedDestinationAmount !== null &&
                    operation.quotedDestinationAmount > 0 &&
                    operation.destinationCurrency
                      ? { amount: operation.quotedDestinationAmount, currency: operation.destinationCurrency }
                      : null
                  }
                  onDone={handleChanged}
                  onCancel={() => setOpenForm(null)}
                />
              </div>
            )}
            {operation.beneficiaries.length === 0 ? (
              <p className="mt-1 text-xs text-muted-foreground">{t("noBeneficiaries")}</p>
            ) : (
              <ul className="mt-1.5 space-y-4">
                {operation.beneficiaries.map((beneficiary) => {
                  const isZelle = beneficiary.beneficiaryType === "zelle";
                  const isCash = beneficiary.beneficiaryType === "efectivo_usd";
                  const isRecarga = beneficiary.beneficiaryType === "recarga";
                  const isComboRecipient = beneficiary.beneficiaryType === "combo";
                  const isMexico = isMexicoBeneficiaryType(beneficiary.beneficiaryType);
                  const amount = resolveBeneficiaryAmount(beneficiary, operation);
                  const currencyLabel = unitLabel(
                    beneficiary.beneficiaryType,
                    beneficiary.currency ?? (isComboRecipient ? "GYD" : operation.destinationCurrency),
                    serviceName,
                  );
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

                      {isEditingBeneficiary && isComboRecipient ? (
                        <ComboBeneficiaryEditFields
                          beneficiary={beneficiary}
                          onCancel={() => setOpenForm(null)}
                          onSaved={handleChanged}
                        />
                      ) : isEditingBeneficiary ? (
                        <BeneficiaryEditFields
                          beneficiary={beneficiary}
                          conversationId={conversationId}
                          amount={amount}
                          showAmountField={isMexico || (operation.beneficiaries.length >= 2 && amount !== null && !isPhoneOnly(operation))}
                          t={t as (key: string) => string}
                          onCancel={() => setOpenForm(null)}
                          onSaved={handleChanged}
                        />
                      ) : (
                        <div className="space-y-1.5">
                          {amount !== null && !isPhoneOnly(operation) && (
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
                          {isComboRecipient && beneficiary.name && (
                            <CopyChip
                              value={beneficiary.name}
                              display={<span className="font-sans text-sm font-medium">{beneficiary.name}</span>}
                              icon={<UserRound className="size-3.5" aria-hidden="true" />}
                              ariaLabel={t("copyValue", { label: t("name") })}
                            />
                          )}
                          {isCash && beneficiary.name && (
                            <CopyChip
                              value={beneficiary.name}
                              display={<span className="font-sans text-sm font-medium">{beneficiary.name}</span>}
                              icon={<UserRound className="size-3.5" aria-hidden="true" />}
                              ariaLabel={t("copyValue", { label: t("name") })}
                            />
                          )}
                          {isCash && (
                            <p className="flex items-center gap-2 px-2 text-xs font-medium text-muted-foreground">
                              <Banknote className="size-3.5" aria-hidden="true" />
                              {serviceName("efectivo_usd")}
                            </p>
                          )}
                          {isMexico && <MexicoRecipientRows beneficiary={beneficiary} />}
                          {!isZelle && !isCash && !isRecarga && !isComboRecipient && !isMexico && beneficiary.cardNumber && (
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
                          {isComboRecipient && beneficiary.contactPhone && (
                            <CopyChip
                              value={beneficiary.contactPhone}
                              icon={<Phone className="size-3.5" aria-hidden="true" />}
                              ariaLabel={t("copyValue", { label: t("contactPhone") })}
                            />
                          )}
                          {isComboRecipient && beneficiary.reference && (
                            <CopyChip
                              value={beneficiary.reference}
                              display={<span className="font-sans text-sm">{beneficiary.reference}</span>}
                              icon={<AtSign className="size-3.5" aria-hidden="true" />}
                              ariaLabel={t("copyValue", { label: t("reference") })}
                            />
                          )}
                          {(isCash || isComboRecipient) && beneficiary.address && (
                            <CopyChip
                              value={beneficiary.address}
                              icon={<MapPin className="size-3.5" aria-hidden="true" />}
                              ariaLabel={t("copyValue", { label: t("address") })}
                            />
                          )}
                          {isCash && (
                            <BeneficiaryIdPhoto
                              beneficiaryId={beneficiary.id}
                              conversationId={conversationId}
                              idPhotoWamid={beneficiary.idPhotoWamid}
                              idPhotoUrl={beneficiary.idPhotoUrl}
                              editable={editable}
                              onChanged={handleChanged}
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
          )}

          {canSetComboCost && (
            <ComboCostField
              // Re-keyed on the saved value so a refetch resets the input to what was saved.
              key={`${operation.id}:${operation.comboCostoGyd ?? "none"}`}
              operationId={operation.id}
              costGyd={operation.comboCostoGyd ?? null}
              completed={operation.status === "completed"}
              onSaved={onChanged}
            />
          )}

          {operation.status === "completed" && <CupPlanBlock operationId={operation.id} />}

          {showCompleteTransfer &&
            (openForm?.kind === "complete" ? (
              <CompleteTransferContainer
                operationId={operation.id}
                conversationId={conversationId}
                isZelle={isZelleOperation(operation)}
                beneficiaries={operation.beneficiaries.map((b) => ({
                  id: b.id,
                  isZelle: b.beneficiaryType === "zelle",
                }))}
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

          {canCloseManually &&
            (openForm?.kind === "close" ? (
              <OperationClosingControl
                operationId={operation.id}
                kind="close"
                needsService={operation.beneficiaries.length === 0 && !operation.deliveryMethod && !isVisa(operation)}
                onDone={handleChanged}
                onCancel={() => setOpenForm(null)}
              />
            ) : (
              <Button
                type="button"
                variant="outline"
                size="lg"
                className="w-full"
                onClick={() => toggleForm({ kind: "close" })}
              >
                {t("closing.closeButton")}
              </Button>
            ))}
        </div>
      )}
    </article>
  );
}

interface BeneficiaryEditFieldsProps {
  beneficiary: RemittanceBeneficiaryRead;
  conversationId: string;
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
function BeneficiaryEditFields({ beneficiary, conversationId, amount, showAmountField, t, onCancel, onSaved }: BeneficiaryEditFieldsProps) {
  const isZelle = beneficiary.beneficiaryType === "zelle";
  const isCash = beneficiary.beneficiaryType === "efectivo_usd";
  const isRecarga = beneficiary.beneficiaryType === "recarga";
  const isMexico = isMexicoBeneficiaryType(beneficiary.beneficiaryType);
  const isMexicoAccount = beneficiary.beneficiaryType === "mexico_cuenta";
  const initialName = beneficiary.name ?? "";
  const initialAddress = beneficiary.address ?? "";
  const initialZelleAccount = beneficiary.zelleAccount ?? "";
  const initialCardDigits = (beneficiary.cardNumber ?? "").replace(/\D/g, "");
  const initialPhoneDigits = (beneficiary.phone ?? "").replace(/\D/g, "");
  // A México recipient edits its own stored amount (the operation-level MXN fallback is not its amount).
  const initialAmount = isMexico ? (beneficiary.amount === null ? "" : String(beneficiary.amount)) : amount === null ? "" : String(amount);

  const [name, setName] = useState(initialName);
  const [zelleAccount, setZelleAccount] = useState(initialZelleAccount);
  const [cardNumber, setCardNumber] = useState(beneficiary.cardNumber ?? "");
  const [phone, setPhone] = useState(beneficiary.phone ?? "");
  const [address, setAddress] = useState(initialAddress);
  const [clabe, setClabe] = useState(beneficiary.clabe ?? "");
  const [bankName, setBankName] = useState(beneficiary.bankName ?? "");
  const [amountValue, setAmountValue] = useState(initialAmount);
  const [photoWamid, setPhotoWamid] = useState<string | null>(beneficiary.idPhotoWamid);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSave() {
    setError(null);
    const changes: Record<string, unknown> = {};

    if (isMexico) {
      const built = buildMexicoBeneficiaryChanges(beneficiary, { name, clabe, bankName, phone, amount: amountValue });
      if (!built.ok) {
        setError(t(built.error));
        return;
      }
      Object.assign(changes, built.changes);
    } else if (isCash) {
      // crm_corregir_beneficiario takes name, phone and address for a cash recipient (never a card or Zelle account).
      // The name is optional (it may be cleared); phone and address are what the delivery needs, so they stay filled.
      const trimmedName = name.trim();
      if (trimmedName !== initialName) changes.name = trimmedName === "" ? null : trimmedName;

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

      const trimmedAddress = address.trim();
      if (trimmedAddress !== initialAddress) {
        if (trimmedAddress === "" && initialAddress !== "") {
          setError(t("cannotBeEmpty"));
          return;
        }
        if (trimmedAddress !== "") changes.address = trimmedAddress;
      }

      // The ID photo is chosen from the chat (migration 233): only a different choice is sent.
      if (photoWamid !== null && photoWamid !== beneficiary.idPhotoWamid) changes.id_photo_wamid = photoWamid;
    } else if (isZelle) {
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
      const digitsCard = isRecarga ? initialCardDigits : cardNumber.replace(/\D/g, "");
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
          if (isRecarga ? !RECHARGE_PHONE_PATTERN.test(digitsPhone) : !PHONE_PATTERN.test(digitsPhone)) {
            setError(t(isRecarga ? "invalidRechargePhone" : "invalidPhone"));
            return;
          }
          changes.phone = digitsPhone;
        }
      }
    }

    if (showAmountField && !isMexico) {
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
    <div className="space-y-1" onKeyDown={handleKeyDown}>
      {showAmountField && (
        <InlineEditField
          id={`inline-amount-${beneficiary.id}`}
          icon={<Banknote className="size-3.5" aria-hidden="true" />}
          value={amountValue}
          onChange={setAmountValue}
          placeholder={isMexico ? t("amountUsd") : t("amount")}
          ariaLabel={isMexico ? t("amountUsd") : t("amount")}
          disabled={pending}
          inputMode="decimal"
          autoFocus
        />
      )}

      {isMexico ? (
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
          {isMexicoAccount && (
            <InlineEditField
              id={`inline-clabe-${beneficiary.id}`}
              icon={<Landmark className="size-3.5" aria-hidden="true" />}
              value={clabe}
              onChange={setClabe}
              placeholder={t("clabe")}
              ariaLabel={t("clabe")}
              disabled={pending}
              inputMode="numeric"
            />
          )}
          <InlineEditField
            id={`inline-bank-${beneficiary.id}`}
            icon={<Building2 className="size-3.5" aria-hidden="true" />}
            value={bankName}
            onChange={setBankName}
            placeholder={t("bank")}
            ariaLabel={t("bank")}
            disabled={pending}
          />
          {!isMexicoAccount && (
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
          )}
        </>
      ) : isCash ? (
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
            id={`inline-phone-${beneficiary.id}`}
            icon={<Phone className="size-3.5" aria-hidden="true" />}
            value={phone}
            onChange={setPhone}
            placeholder={t("phone")}
            ariaLabel={t("phone")}
            disabled={pending}
            inputMode="numeric"
          />
          <InlineEditField
            id={`inline-address-${beneficiary.id}`}
            icon={<MapPin className="size-3.5" aria-hidden="true" />}
            value={address}
            onChange={setAddress}
            placeholder={t("address")}
            ariaLabel={t("address")}
            disabled={pending}
          />
          <IdPhotoFormRow conversationId={conversationId} value={photoWamid} disabled={pending} onChange={setPhotoWamid} />
        </>
      ) : isZelle ? (
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
          {!isRecarga && (
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
          )}
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

      <ConfirmCancelButtons onCancel={onCancel} onConfirm={() => void handleSave()} pending={pending} />
    </div>
  );
}
