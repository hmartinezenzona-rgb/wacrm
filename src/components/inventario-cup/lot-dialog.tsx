"use client";

import { useState, type FormEvent, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { validateLotForm } from "@/lib/cup-inventory/forms";
import type { InventoryLot } from "@/lib/cup-inventory/read-model";

export interface LotFormValue {
  amountCup: number;
  rateCupPerUsdt: number;
  note?: string;
}

interface LotDialogProps {
  open: boolean;
  cardName: string;
  /** The lot being corrected; null loads a new one. */
  lot: InventoryLot | null;
  /** Card picker shown above the fields (the "Comprar saldo" flow). */
  picker?: ReactNode;
  onClose: () => void;
  /** Saves; resolves to an error message, or null when it worked. */
  onSave: (value: LotFormValue) => Promise<string | null>;
}

export function LotDialog({ open, cardName, lot, picker, onClose, onSave }: LotDialogProps) {
  return (
    <Dialog open={open} onOpenChange={(next) => (next ? undefined : onClose())}>
      <DialogContent>
        {open ? <LotForm key={lot?.id ?? "new"} cardName={cardName} lot={lot} picker={picker} onClose={onClose} onSave={onSave} /> : null}
      </DialogContent>
    </Dialog>
  );
}

function LotForm({ cardName, lot, picker, onClose, onSave }: Omit<LotDialogProps, "open">) {
  const t = useTranslations("CupInventory");
  const [amount, setAmount] = useState(lot ? String(lot.amountCup) : "");
  const [rate, setRate] = useState(lot ? String(lot.rateCupPerUsdt) : "");
  const [note, setNote] = useState(lot?.note ?? "");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function submit(event: FormEvent) {
    event.preventDefault();
    const result = validateLotForm({ amount, rate, note });
    if (!result.ok) {
      setError(t(`errors.${result.errorKey}`));
      return;
    }
    setSaving(true);
    setError(null);
    const failure = await onSave(result.value);
    setSaving(false);
    if (failure) setError(failure);
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4">
      <DialogHeader>
        <DialogTitle>{lot ? t("lotForm.titleEdit", { card: cardName }) : t("lotForm.titleNew", { card: cardName })}</DialogTitle>
      </DialogHeader>
      {picker}
      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="cup-lot-amount">{t("lotForm.amount")}</Label>
          <Input id="cup-lot-amount" value={amount} inputMode="decimal" onChange={(e) => setAmount(e.target.value)} autoFocus />
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="cup-lot-rate">{t("lotForm.rate")}</Label>
          <Input id="cup-lot-rate" value={rate} inputMode="decimal" onChange={(e) => setRate(e.target.value)} />
        </div>
      </div>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="cup-lot-note">{t("lotForm.note")}</Label>
        <Input id="cup-lot-note" value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} />
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
        <Button type="submit" disabled={saving}>
          {saving ? <Loader2 className="size-4 animate-spin" aria-hidden="true" /> : null}
          {saving ? t("actions.saving") : t("actions.save")}
        </Button>
      </DialogFooter>
    </form>
  );
}
