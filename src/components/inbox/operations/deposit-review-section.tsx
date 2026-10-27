"use client";

import { useState, type ChangeEvent } from "react";
import { useTranslations } from "next-intl";
import { AlertTriangle, Banknote, CircleCheck, Hash } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { FieldRow, UnderlineInput } from "./edit-form-fields";
import { NotifyToggle } from "./notify-toggle";
import { ReceiptReviewViewer } from "./receipt-review-viewer";
import type { DepositReceipt, OperationReceiptsRead, VerifyDepositItem } from "@/lib/remittance-operations/types";

/** The verified state's destination-amount row: a resolved amount to
 *  display, or a "missing" state rendered as an amber warning. `null`
 *  (the prop itself) means "no data for this operation" and omits the
 *  row entirely — see `DepositReviewSectionProps.summaryAmount`. */
export type SummaryAmount = { kind: "amount"; display: string } | { kind: "missing" };

interface DepositReviewSectionProps {
  data: OperationReceiptsRead;
  /** `data.canVerify` AND the current user can edit this operation — gates
   *  the interactive verify UI (inputs, verify/force actions). Which
   *  business branch renders below (verified vs. awaiting verification)
   *  is decided from `data.canVerify`/`data.status` instead, so a
   *  read-only viewer still sees the right state, just without actions. */
  canVerify: boolean;
  canForce: boolean;
  busy: boolean;
  result: { kind: "success" | "error"; message: string } | null;
  /** `notify` is the bell: whether the customer gets the WhatsApp message. */
  onVerify: (items: VerifyDepositItem[], notify: boolean) => void;
  onForce: (notify: boolean) => void;
  /** Destination amount row shown in the verified state, computed by the
   *  card from the operation's beneficiaries. `undefined`/`null` omits
   *  the row (multiple beneficiaries, or none known). */
  summaryAmount?: SummaryAmount | null;
  /** Opens the operation correction form (only passed when the card is
   *  editable); renders the missing-amount row as a button when given,
   *  plain amber text otherwise. */
  onAddAmount?: () => void;
}

interface Draft {
  ref: string;
  amount: string;
}

const VERIFIED_STATUSES: ReadonlyArray<string> = ["ready_to_transfer", "transferring", "completed"];

function draftsFrom(receipts: DepositReceipt[]): Record<string, Draft> {
  const map: Record<string, Draft> = {};
  for (const receipt of receipts) {
    map[receipt.compId] = {
      ref: receipt.declaredRef ?? "",
      amount: receipt.declaredAmount === null ? "" : String(receipt.declaredAmount),
    };
  }
  return map;
}

/** A receipt is eligible for the next verify attempt when it has no
 *  matched deposit yet and its current draft has a non-empty ref and a
 *  positive amount. */
function isEligible(receipt: DepositReceipt, draft: Draft | undefined): boolean {
  if (!draft) return false;
  if (receipt.matchedDeposit !== null) return false;
  if (draft.ref.trim() === "") return false;
  return Number(draft.amount) > 0;
}

/** First receipt whose matched deposit or declared reference can serve as
 *  the verified-state ref chip's value. */
function verifiedRef(receipts: DepositReceipt[]): string | null {
  for (const receipt of receipts) {
    const ref = receipt.matchedDeposit?.transId ?? receipt.declaredRef;
    if (ref) return ref;
  }
  return null;
}

/**
 * Presentational deposit review block rendered inside an expanded
 * operation card. No fetch here — the container owns data loading and the
 * verify/force network calls. Two business states, both driven by
 * `data.canVerify`/`data.status` (the operation's own state, independent
 * of who's viewing): verified (a confirmation line, the `summaryAmount`
 * row — plain text, or an amber "amount missing" row that's a button only
 * when `onAddAmount` is given — and a plain TransID line, no image, rows
 * omitted when their data is null) and awaiting verification (the first
 * unmatched receipt's viewer plus a directly-bound "Amount
 * deposited"/"TransID" draft, gated on the `canVerify` prop for whether
 * those are interactive or read-only). Every other state renders nothing.
 */
export function DepositReviewSection({
  data,
  canVerify,
  canForce,
  busy,
  result,
  onVerify,
  onForce,
  summaryAmount,
  onAddAmount,
}: DepositReviewSectionProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [drafts, setDrafts] = useState<Record<string, Draft>>(() => draftsFrom(data.receipts));
  const [unmatchedIndex, setUnmatchedIndex] = useState(0);
  const [forcing, setForcing] = useState(false);
  const [notify, setNotify] = useState(true);

  // Reset drafts (and the receipt switcher) whenever the container hands
  // us a new `data.receipts` (initial load or a refetch after a
  // verify/force attempt) so drafts always start from the latest declared
  // values. Adjusted during render (React's documented pattern for this)
  // rather than in an effect.
  const [receiptsForDrafts, setReceiptsForDrafts] = useState(data.receipts);
  if (data.receipts !== receiptsForDrafts) {
    setReceiptsForDrafts(data.receipts);
    setDrafts(draftsFrom(data.receipts));
    setUnmatchedIndex(0);
  }

  function updateDraft(compId: string, patch: Partial<Draft>) {
    setDrafts((prev) => ({
      ...prev,
      [compId]: { ...(prev[compId] ?? { ref: "", amount: "" }), ...patch },
    }));
  }

  const items: VerifyDepositItem[] = data.receipts
    .filter((receipt) => isEligible(receipt, drafts[receipt.compId]))
    .map((receipt) => ({
      ref: drafts[receipt.compId]!.ref.trim(),
      amount: Number(drafts[receipt.compId]!.amount),
    }));

  // Informational, never blocking: the recipients may add up to more than the
  // verified deposit covers (the bot registers everything the customer gives).
  // The admin sees exactly what is missing and still decides whether to deliver.
  const shortfallNote =
    VERIFIED_STATUSES.includes(data.status) && data.saldo !== null && data.saldo > 0 ? (
      <p className="flex items-center gap-2 text-sm leading-5 text-amber-700 dark:text-amber-400">
        <span className="flex w-4 shrink-0 items-center justify-center">
          <AlertTriangle className="size-3.5" aria-hidden="true" />
        </span>
        {t("depositReview.shortfall", {
          amount: new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(data.saldo),
          currency: data.moneda ?? "GYD",
        })}
      </p>
    ) : null;

  function cancelForce() {
    setForcing(false);
  }

  function confirmForce() {
    onForce(notify);
    cancelForce();
  }

  if (!data.canVerify && VERIFIED_STATUSES.includes(data.status)) {
    const ref = verifiedRef(data.receipts);
    return (
      <div className="space-y-1">
        <div className="flex items-center gap-2 text-sm leading-5 text-foreground">
          <span className="flex w-4 shrink-0 items-center justify-center">
            <CircleCheck className="size-3.5 text-status-success" aria-hidden="true" />
          </span>
          {t("depositReview.verified")}
        </div>

        {summaryAmount?.kind === "amount" && (
          <div className="flex items-center gap-2 text-sm leading-5">
            <span className="flex w-4 shrink-0 items-center justify-center">
              <Banknote className="size-3.5 text-muted-foreground" aria-hidden="true" />
            </span>
            <span className="font-medium tabular-nums">{summaryAmount.display}</span>
          </div>
        )}

        {summaryAmount?.kind === "missing" &&
          (onAddAmount ? (
            <button
              type="button"
              onClick={onAddAmount}
              className="flex items-center gap-2 text-sm leading-5 text-amber-700 dark:text-amber-400"
            >
              <span className="flex w-4 shrink-0 items-center justify-center">
                <AlertTriangle className="size-3.5" aria-hidden="true" />
              </span>
              {t("amountMissing")}
            </button>
          ) : (
            <p className="flex items-center gap-2 text-sm leading-5 text-amber-700 dark:text-amber-400">
              <span className="flex w-4 shrink-0 items-center justify-center">
                <AlertTriangle className="size-3.5" aria-hidden="true" />
              </span>
              {t("amountMissing")}
            </p>
          ))}

        {shortfallNote}

        {ref && (
          <div className="flex items-center gap-2 text-sm leading-5 font-mono">
            <span className="flex w-4 shrink-0 items-center justify-center">
              <Hash className="size-3.5 text-muted-foreground" aria-hidden="true" />
            </span>
            {ref}
          </div>
        )}
      </div>
    );
  }

  if (!data.canVerify) return null;

  const unmatched = data.receipts.filter((receipt) => receipt.matchedDeposit === null);
  const current = unmatched.length === 0 ? null : unmatched[Math.min(unmatchedIndex, unmatched.length - 1)];
  const draft = current ? (drafts[current.compId] ?? { ref: "", amount: "" }) : null;

  return (
    <div className="space-y-2">
      {shortfallNote}

      {result && (
        <p
          role="status"
          className={result.kind === "success" ? "text-xs text-emerald-600" : "text-xs text-destructive"}
        >
          {result.message}
        </p>
      )}

      {current && draft && (
        <div className="space-y-2">
          {unmatched.length > 1 && (
            <div className="flex items-center justify-center gap-2 text-[10px] text-muted-foreground">
              <button
                type="button"
                onClick={() => setUnmatchedIndex((i) => Math.max(0, i - 1))}
                disabled={unmatchedIndex === 0}
                className="underline underline-offset-2 disabled:opacity-40 disabled:no-underline"
              >
                ‹
              </button>
              {t("depositReview.receiptPosition", { current: unmatchedIndex + 1, total: unmatched.length })}
              <button
                type="button"
                onClick={() => setUnmatchedIndex((i) => Math.min(unmatched.length - 1, i + 1))}
                disabled={unmatchedIndex === unmatched.length - 1}
                className="underline underline-offset-2 disabled:opacity-40 disabled:no-underline"
              >
                ›
              </button>
            </div>
          )}

          <ReceiptReviewViewer src={current.mediaUrl ?? ""} alt={t("depositReview.receipt")} />

          {canVerify ? (
            <>
              <div className="space-y-1">
                <FieldRow label={t("depositReview.amountDeposited")} htmlFor={`deposit-review-amount-${current.compId}`}>
                <UnderlineInput
                  id={`deposit-review-amount-${current.compId}`}
                  inputMode="numeric"
                  value={draft.amount}
                  onChange={(event: ChangeEvent<HTMLInputElement>) =>
                    updateDraft(current.compId, { amount: event.target.value })
                  }
                />
                </FieldRow>
                <FieldRow label={t("depositReview.transId")} htmlFor={`deposit-review-ref-${current.compId}`}>
                <UnderlineInput
                  id={`deposit-review-ref-${current.compId}`}
                  className="font-mono"
                  inputMode="numeric"
                  value={draft.ref}
                  onChange={(event: ChangeEvent<HTMLInputElement>) =>
                    updateDraft(current.compId, { ref: event.target.value })
                  }
                />
                </FieldRow>
              </div>

              <div className="flex items-center gap-1">
                <Button
                  type="button"
                  className="flex-1"
                  disabled={busy || items.length === 0}
                  onClick={() => onVerify(items, notify)}
                >
                  {t("depositReview.verify")}
                </Button>
                <NotifyToggle notify={notify} onChange={setNotify} disabled={busy} />
              </div>
            </>
          ) : (
            <div className="space-y-1 text-xs">
              <p>
                <span className="text-muted-foreground">{t("depositReview.amountDeposited")}: </span>
                <span className="font-medium tabular-nums">{draft.amount || "—"}</span>
              </p>
              <p>
                <span className="text-muted-foreground">{t("depositReview.transId")}: </span>
                <span className="font-mono">{draft.ref || "—"}</span>
              </p>
            </div>
          )}
        </div>
      )}

      {/* B4.3 — force verification must not depend on an unmatched receipt
         existing: `data.canVerify` (099's `v_can_verify`) is purely
         status-based, so an operation the bot never logged a receipt for
         (e.g. paused before one arrived) can still be stuck awaiting
         verification with `receipts: []`. Kept outside the `current &&
         draft` block above so it renders whether or not there is a
         receipt to review. */}
      {canVerify && canForce && (
        <>
          {!forcing && (
            <button
              type="button"
              className="w-full text-center text-xs text-muted-foreground underline underline-offset-2"
              onClick={() => setForcing(true)}
            >
              {t("depositReview.force")}
            </button>
          )}

          {forcing && (
            <div className="border-l-2 border-border pl-2" onKeyDown={busy ? undefined : cancelOnEscape(cancelForce)}>
              <ConfirmCancelButtons
                onCancel={cancelForce}
                onConfirm={confirmForce}
                cancelLabel={t("depositReview.cancel")}
                confirmLabel={t("depositReview.forceConfirm")}
                pending={busy}
              >
                <NotifyToggle notify={notify} onChange={setNotify} disabled={busy} />
              </ConfirmCancelButtons>
            </div>
          )}
        </>
      )}
    </div>
  );
}
