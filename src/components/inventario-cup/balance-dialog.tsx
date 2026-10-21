"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { formatCup } from "@/lib/cup-inventory/format";
import { balanceDifference, validateBalanceForm } from "@/lib/cup-inventory/forms";

export interface BalanceFormValue {
  balanceCup: number;
  reason?: string;
}

interface BalanceDialogProps {
  open: boolean;
  cardName: string;
  currentBalanceCup: number;
  onClose: () => void;
  /** Saves; resolves to an error message, or null when it worked. */
  onSave: (value: BalanceFormValue) => Promise<string | null>;
}

/** "+27 160" / "−22 840" / "0": the signed change a typed balance would make. */
function signed(value: number): string {
  if (value === 0) return "0";
  return `${value > 0 ? "+" : "−"}${formatCup(Math.abs(value))}`;
}

export function BalanceDialog({ open, cardName, currentBalanceCup, onClose, onSave }: BalanceDialogProps) {
  return (
    <Dialog open={open} onOpenChange={(next) => (next ? undefined : onClose())}>
      <DialogContent>
        {open ? <BalanceForm cardName={cardName} currentBalanceCup={currentBalanceCup} onClose={onClose} onSave={onSave} /> : null}
      </DialogContent>
    </Dialog>
  );
}

function BalanceForm({ cardName, currentBalanceCup, onClose, onSave }: Omit<BalanceDialogProps, "open">) {
  const t = useTranslations("CupInventory");
  const [balance, setBalance] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const result = validateBalanceForm({ balance, reason, currentBalanceCup });
  const difference = balanceDifference(balance, currentBalanceCup);
  // Typing is not an error yet: only say what is wrong once there is something typed.
  const hint = !result.ok && balance.trim() !== "" ? t(`errors.${result.errorKey}`) : null;

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!result.ok) return;
    setSaving(true);
    setError(null);
    const failure = await onSave(result.value);
    setSaving(false);
    if (failure) setError(failure);
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4">
      <DialogHeader>
        <DialogTitle>{t("balanceForm.title", { card: cardName })}</DialogTitle>
        <DialogDescription>{t("balanceForm.hint")}</DialogDescription>
      </DialogHeader>
      <dl className="grid grid-cols-2 gap-3">
        <div>
          <dt className="text-muted-foreground text-xs">{t("balanceForm.current")}</dt>
          <dd className="text-foreground text-base font-semibold tabular-nums">{formatCup(currentBalanceCup)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground text-xs">{t("balanceForm.difference")}</dt>
          <dd className="text-foreground text-base font-semibold tabular-nums">{difference === null ? "–" : signed(difference)}</dd>
        </div>
      </dl>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="cup-balance-value">{t("balanceForm.balance")}</Label>
        <Input id="cup-balance-value" value={balance} inputMode="decimal" onChange={(e) => setBalance(e.target.value)} autoFocus />
        {hint ? <p className="text-muted-foreground text-xs">{hint}</p> : null}
      </div>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="cup-balance-reason">{t("balanceForm.reason")}</Label>
        <Input id="cup-balance-reason" value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} />
      </div>
      {error ? (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      ) : null}
      <DialogFooter>
        <Button type="button" variant="outline" onClick={onClose} disabled={saving}>
          {t("actions.cancel")}
        </Button>
        <Button type="submit" disabled={saving || !result.ok}>
          {saving ? <Loader2 className="size-4 animate-spin" aria-hidden="true" /> : null}
          {saving ? t("actions.saving") : t("balanceForm.submit")}
        </Button>
      </DialogFooter>
    </form>
  );
}
