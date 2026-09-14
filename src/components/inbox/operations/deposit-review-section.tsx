"use client";

import { useState, type ChangeEvent } from "react";
import { useTranslations } from "next-intl";
import { Circle, CircleCheck, Hash, Pencil, Receipt as ReceiptIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog";
import { CopyButton } from "./copy-button";
import type { DepositReceipt, OperationReceiptsRead, VerifyDepositItem } from "@/lib/remittance-operations/types";

interface DepositReviewSectionProps {
  data: OperationReceiptsRead;
  /** `data.canVerify` AND the current user can edit this operation. */
  canVerify: boolean;
  canForce: boolean;
  busy: boolean;
  result: { kind: "success" | "error"; message: string } | null;
  onVerify: (items: VerifyDepositItem[]) => void;
  onForce: (reason: string) => void;
}

interface Draft {
  ref: string;
  amount: string;
}

const MIN_FORCE_REASON_LENGTH = 5;

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

function money(amount: number | null, currency: string | null): string {
  if (amount === null) return "—";
  const formatted = new Intl.NumberFormat("en-US").format(amount);
  return currency ? `${formatted} ${currency}` : formatted;
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

/**
 * Presentational: the "Receipts" block rendered above the beneficiaries
 * list inside an expanded operation card (panel 16). No fetch here — the
 * container owns data loading and the verify/force network calls. This
 * component keeps a local per-receipt draft {ref, amount} (initialized
 * from declaredRef/declaredAmount, resettable via the pencil edit form)
 * used to build the items sent on verify, plus local UI state for the
 * inline edit and force-reason forms and the enlarged-image dialog.
 */
export function DepositReviewSection({
  data,
  canVerify,
  canForce,
  busy,
  result,
  onVerify,
  onForce,
}: DepositReviewSectionProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [drafts, setDrafts] = useState<Record<string, Draft>>(() => draftsFrom(data.receipts));
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState<Draft>({ ref: "", amount: "" });
  const [enlargedUrl, setEnlargedUrl] = useState<string | null>(null);
  const [forcing, setForcing] = useState(false);
  const [reason, setReason] = useState("");

  // Reset drafts whenever the container hands us a new `data.receipts`
  // (initial load or a refetch after a verify/force attempt) so drafts
  // always start from the latest declared values. Adjusted during render
  // (React's documented pattern for this) rather than in an effect, so it
  // takes effect before the first paint of the new data instead of after
  // an extra render.
  const [receiptsForDrafts, setReceiptsForDrafts] = useState(data.receipts);
  if (data.receipts !== receiptsForDrafts) {
    setReceiptsForDrafts(data.receipts);
    setDrafts(draftsFrom(data.receipts));
  }

  function startEdit(receipt: DepositReceipt) {
    setEditDraft(
      drafts[receipt.compId] ?? {
        ref: receipt.declaredRef ?? "",
        amount: receipt.declaredAmount === null ? "" : String(receipt.declaredAmount),
      },
    );
    setEditingId(receipt.compId);
  }

  function cancelEdit() {
    setEditingId(null);
  }

  function saveEdit(compId: string) {
    setDrafts((prev) => ({ ...prev, [compId]: editDraft }));
    setEditingId(null);
  }

  const items: VerifyDepositItem[] = data.receipts
    .filter((receipt) => isEligible(receipt, drafts[receipt.compId]))
    .map((receipt) => ({
      ref: drafts[receipt.compId]!.ref.trim(),
      amount: Number(drafts[receipt.compId]!.amount),
    }));

  const trimmedReason = reason.trim();
  const canConfirmForce = trimmedReason.length >= MIN_FORCE_REASON_LENGTH;

  function cancelForce() {
    setForcing(false);
    setReason("");
  }

  function confirmForce() {
    onForce(trimmedReason);
    cancelForce();
  }

  return (
    <div className="space-y-2">
      <h4 className="text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
        {t("depositReview.title", { count: data.receipts.length })}
      </h4>

      <ul className="space-y-1.5">
        {data.receipts.map((receipt) => {
          const draft = drafts[receipt.compId] ?? { ref: "", amount: "" };
          const isEditing = editingId === receipt.compId;

          return (
            <li key={receipt.compId} className="flex gap-2 rounded-md bg-muted/60 p-1.5 text-xs">
              <button
                type="button"
                aria-label={t("depositReview.enlarge")}
                title={t("depositReview.enlarge")}
                onClick={() => setEnlargedUrl(receipt.mediaUrl)}
                className="size-12 shrink-0 overflow-hidden rounded-md border border-border bg-muted"
              >
                {receipt.mediaUrl && (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={receipt.mediaUrl} alt="" className="size-full object-cover" />
                )}
              </button>

              <div className="min-w-0 flex-1 space-y-1">
                <div className="flex items-center gap-1.5">
                  <ReceiptIcon className="size-3.5 shrink-0 text-muted-foreground" aria-hidden="true" />
                  <span className="ml-auto min-w-0 truncate text-right font-semibold tabular-nums text-foreground">
                    {money(receipt.declaredAmount, receipt.declaredCurrency)}
                  </span>
                  {canVerify && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon-xs"
                      aria-label={t("depositReview.edit")}
                      title={t("depositReview.edit")}
                      onClick={() => startEdit(receipt)}
                    >
                      <Pencil aria-hidden="true" />
                    </Button>
                  )}
                </div>

                <div className="flex items-center gap-1.5">
                  <Hash className="size-3.5 shrink-0 text-muted-foreground" aria-hidden="true" />
                  <span className="ml-auto min-w-0 truncate text-right font-medium tabular-nums text-foreground">
                    {draft.ref || "—"}
                  </span>
                  <CopyButton value={draft.ref} ariaLabel={`${t("copy")} ${t("depositReview.ref")}`} />
                </div>

                <div className="flex items-center gap-1.5 text-muted-foreground">
                  {receipt.matchedDeposit ? (
                    <>
                      <CircleCheck className="size-3.5 shrink-0" aria-hidden="true" />
                      <span>{t("depositReview.matched", { transId: receipt.matchedDeposit.transId })}</span>
                    </>
                  ) : (
                    <>
                      <Circle className="size-3.5 shrink-0" aria-hidden="true" />
                      <span>{t("depositReview.notMatched")}</span>
                    </>
                  )}
                </div>

                {isEditing && (
                  <div className="space-y-1.5 rounded-md border border-border bg-background p-1.5">
                    <div className="space-y-1">
                      <Label htmlFor={`deposit-review-ref-${receipt.compId}`}>{t("depositReview.ref")}</Label>
                      <Input
                        id={`deposit-review-ref-${receipt.compId}`}
                        value={editDraft.ref}
                        onChange={(event: ChangeEvent<HTMLInputElement>) =>
                          setEditDraft((prev) => ({ ...prev, ref: event.target.value }))
                        }
                      />
                    </div>
                    <div className="space-y-1">
                      <Label htmlFor={`deposit-review-amount-${receipt.compId}`}>{t("depositReview.amount")}</Label>
                      <Input
                        id={`deposit-review-amount-${receipt.compId}`}
                        value={editDraft.amount}
                        onChange={(event: ChangeEvent<HTMLInputElement>) =>
                          setEditDraft((prev) => ({ ...prev, amount: event.target.value }))
                        }
                      />
                    </div>
                    <div className="flex justify-end gap-2">
                      <Button type="button" variant="outline" size="sm" onClick={cancelEdit}>
                        {t("depositReview.cancel")}
                      </Button>
                      <Button type="button" size="sm" onClick={() => saveEdit(receipt.compId)}>
                        {t("depositReview.save")}
                      </Button>
                    </div>
                  </div>
                )}
              </div>
            </li>
          );
        })}
      </ul>

      {canVerify && (
        <Button type="button" className="w-full" disabled={busy || items.length === 0} onClick={() => onVerify(items)}>
          {t("depositReview.verify")}
        </Button>
      )}

      {canVerify && canForce && !forcing && (
        <button
          type="button"
          className="w-full text-center text-xs text-muted-foreground underline underline-offset-2"
          onClick={() => setForcing(true)}
        >
          {t("depositReview.force")}
        </button>
      )}

      {canVerify && canForce && forcing && (
        <div className="space-y-1.5 rounded-md border border-border bg-muted/40 p-1.5">
          <div className="space-y-1">
            <Label htmlFor="deposit-review-force-reason">{t("depositReview.forceReason")}</Label>
            <Input
              id="deposit-review-force-reason"
              value={reason}
              onChange={(event: ChangeEvent<HTMLInputElement>) => setReason(event.target.value)}
            />
          </div>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" size="sm" onClick={cancelForce}>
              {t("depositReview.cancel")}
            </Button>
            <Button type="button" size="sm" disabled={!canConfirmForce} onClick={confirmForce}>
              {t("depositReview.forceConfirm")}
            </Button>
          </div>
        </div>
      )}

      {result && (
        <p
          role="status"
          className={result.kind === "success" ? "text-xs text-emerald-600" : "text-xs text-destructive"}
        >
          {result.message}
        </p>
      )}

      <Dialog open={enlargedUrl !== null} onOpenChange={(open) => !open && setEnlargedUrl(null)}>
        <DialogContent className="sm:max-w-lg">
          <DialogTitle className="sr-only">{t("depositReview.enlarge")}</DialogTitle>
          {enlargedUrl && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={enlargedUrl} alt="" className="max-h-[80vh] w-full object-contain" />
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
}
