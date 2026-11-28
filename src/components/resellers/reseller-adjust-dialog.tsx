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
import { adjustReseller } from "@/lib/resellers/client";
import { formatGyd } from "@/lib/resellers/format";

export interface ResellerAdjustDialogProps {
  open: boolean;
  contactId: string;
  resellerName?: string | null;
  currentTotalGyd: number;
  onClose: () => void;
  /** Receives the total after the adjustment so the caller can refresh. */
  onSaved?: (totalAfterGyd: number) => void;
}

/**
 * Manual, signed GYD adjustment. Adjustments are append-only: a correction is
 * a new adjustment, not an edit. The dialog previews the resulting total.
 */
export function ResellerAdjustDialog({
  open,
  contactId,
  resellerName,
  currentTotalGyd,
  onClose,
  onSaved,
}: ResellerAdjustDialogProps) {
  const t = useTranslations("Resellers.adjustDialog");
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setAmount("");
    setReason("");
    setError(null);
    setSaving(false);
  }, [open, contactId]);

  const parsed = Number(amount);
  const valid =
    amount.trim() !== "" &&
    Number.isFinite(parsed) &&
    parsed !== 0 &&
    Math.abs(parsed) < 1e12;
  const typed = amount.trim() !== "";
  const preview = valid ? currentTotalGyd + parsed : null;

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!valid) return;
    setSaving(true);
    setError(null);
    try {
      const result = await adjustReseller(contactId, {
        amountGyd: parsed,
        reason: reason.trim() || null,
      });
      onSaved?.(result.totalAfterGyd);
      onClose();
    } catch {
      setError(t("error"));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={(next) => (next ? undefined : onClose())}>
      <DialogContent>
        {open ? (
          <form onSubmit={submit} className="flex flex-col gap-4">
            <DialogHeader>
              <DialogTitle>{t("title", { name: resellerName ?? "" })}</DialogTitle>
              <DialogDescription>{t("amountHint")}</DialogDescription>
            </DialogHeader>
            <dl className="grid grid-cols-2 gap-3">
              <div>
                <dt className="text-xs text-muted-foreground">{t("current")}</dt>
                <dd className="text-base font-semibold tabular-nums text-foreground">
                  {formatGyd(currentTotalGyd)}
                </dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">{t("preview")}</dt>
                <dd className="text-base font-semibold tabular-nums text-foreground">
                  {preview === null ? "—" : formatGyd(preview)}
                </dd>
              </div>
            </dl>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="reseller-adjust-amount">{t("amount")}</Label>
              <Input
                id="reseller-adjust-amount"
                value={amount}
                inputMode="decimal"
                onChange={(event) => setAmount(event.target.value)}
                autoFocus
              />
              {typed && !valid ? (
                <p className="text-xs text-muted-foreground">{t("invalidAmount")}</p>
              ) : null}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="reseller-adjust-reason">{t("reason")}</Label>
              <Input
                id="reseller-adjust-reason"
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
              <Button type="submit" disabled={saving || !valid}>
                {saving ? <Loader2 className="size-4 animate-spin" aria-hidden="true" /> : null}
                {t("submit")}
              </Button>
            </DialogFooter>
          </form>
        ) : null}
      </DialogContent>
    </Dialog>
  );
}
