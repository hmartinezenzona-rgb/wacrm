"use client";

import { useEffect, useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  ResellerConflictError,
  resetAllResellers,
  resetReseller,
} from "@/lib/resellers/client";
import { formatGyd } from "@/lib/resellers/format";

type ResetMode = "single" | "all";

export interface ResellerResetDialogProps {
  open: boolean;
  mode: ResetMode;
  /** Single mode: the reseller contact being reset. */
  contactId?: string;
  /** Single mode: shown in the confirmation title. */
  resellerName?: string | null;
  /** The amount being closed (single total or grand total). */
  amountGyd: number;
  /** All mode: every reseller-tagged contact, to derive the skipped ones. */
  resellerIds?: string[];
  onClose: () => void;
  /** Called after a successful reset so the caller can refresh its list. */
  onDone?: () => void;
}

interface ResetSummary {
  closed: number;
  skipped: number;
}

/**
 * Confirmation for a counter reset. Reset never touches money: it appends a
 * marker and restarts the counter from now. The dialog shows the amount the
 * admin is confirming and sends it as the expected total; if the total moved
 * meanwhile (409) it reloads with the current amount and asks again.
 */
export function ResellerResetDialog({
  open,
  mode,
  contactId,
  resellerName,
  amountGyd,
  resellerIds = [],
  onClose,
  onDone,
}: ResellerResetDialogProps) {
  const t = useTranslations("Resellers.resetDialog");
  const [reason, setReason] = useState("");
  const [displayAmount, setDisplayAmount] = useState(amountGyd);
  const [conflictAmount, setConflictAmount] = useState<number | null>(null);
  const [summary, setSummary] = useState<ResetSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setReason("");
    setDisplayAmount(amountGyd);
    setConflictAmount(null);
    setSummary(null);
    setError(null);
    setSaving(false);
  }, [open, amountGyd, mode, contactId]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (mode === "single" && !contactId) return;
    setSaving(true);
    setError(null);
    try {
      if (mode === "single") {
        await resetReseller(contactId as string, {
          reason: reason.trim() || null,
          expectedTotalGyd: displayAmount,
        });
        onDone?.();
        onClose();
      } else {
        const batch = await resetAllResellers({
          reason: reason.trim() || null,
          expectedGrandTotalGyd: displayAmount,
        });
        const written = new Set(batch.resets.map((reset) => reset.contactId));
        setSummary({
          closed: batch.count,
          skipped: resellerIds.filter((id) => !written.has(id)).length,
        });
        onDone?.();
      }
    } catch (caught) {
      if (caught instanceof ResellerConflictError) {
        if (caught.currentAmountGyd !== null) setDisplayAmount(caught.currentAmountGyd);
        setConflictAmount(caught.currentAmountGyd ?? displayAmount);
      } else {
        setError(t("error"));
      }
    } finally {
      setSaving(false);
    }
  }

  const title =
    mode === "single" ? t("titleSingle", { name: resellerName ?? "" }) : t("titleAll");
  const confirmLabel = mode === "single" ? t("confirmSingle") : t("confirmAll");

  return (
    <Dialog open={open} onOpenChange={(next) => (next ? undefined : onClose())}>
      <DialogContent>
        {open ? (
          summary ? (
            <>
              <DialogHeader>
                <DialogTitle>{t("summaryTitle")}</DialogTitle>
                <DialogDescription>{t("counterOnly")}</DialogDescription>
              </DialogHeader>
              <div className="flex flex-col gap-1 text-sm text-foreground">
                <p>{t("summaryCount", { count: summary.closed })}</p>
                {summary.skipped > 0 ? (
                  <p className="text-muted-foreground">
                    {t("summarySkipped", { count: summary.skipped })}
                  </p>
                ) : null}
              </div>
              <DialogFooter>
                <Button type="button" onClick={onClose}>
                  {t("done")}
                </Button>
              </DialogFooter>
            </>
          ) : (
            <form onSubmit={submit} className="flex flex-col gap-4">
              <DialogHeader>
                <DialogTitle>{title}</DialogTitle>
                <DialogDescription>{t("counterOnly")}</DialogDescription>
              </DialogHeader>
              <div>
                <p className="text-xs text-muted-foreground">{t("amountLabel")}</p>
                <p className="text-base font-semibold tabular-nums text-foreground">
                  {formatGyd(displayAmount)}
                </p>
              </div>
              {conflictAmount !== null ? (
                <p role="status" className="text-sm text-amber-600 dark:text-amber-400">
                  {t("conflict", { amount: formatGyd(conflictAmount) })}
                </p>
              ) : null}
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="reseller-reset-reason">{t("reason")}</Label>
                <Input
                  id="reseller-reset-reason"
                  value={reason}
                  maxLength={500}
                  placeholder={t("reasonPlaceholder")}
                  onChange={(event) => setReason(event.target.value)}
                />
              </div>
              {error ? (
                <p role="alert" className="text-sm text-red-600 dark:text-red-400">
                  {error}
                </p>
              ) : null}
              <DialogFooter>
                <Button type="button" variant="outline" onClick={onClose} disabled={saving}>
                  {t("cancel")}
                </Button>
                <Button type="submit" disabled={saving}>
                  {saving ? <Loader2 className="size-4 animate-spin" aria-hidden="true" /> : null}
                  {confirmLabel}
                </Button>
              </DialogFooter>
            </form>
          )
        ) : null}
      </DialogContent>
    </Dialog>
  );
}
