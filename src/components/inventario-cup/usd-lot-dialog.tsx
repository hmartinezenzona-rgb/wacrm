"use client";

import { useState, type FormEvent, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { validateUsdLotForm } from "@/lib/usd-inventory/forms";
import { discountToUsdtPaid, formatUsd, parsePercent, parseUsdNumber } from "@/lib/usd-inventory/format";
import type { UnifiedLot } from "@/lib/card-inventory/unify";

export interface UsdLotFormValue {
  amountUsd: number;
  usdtPaid: number;
  note?: string;
}

interface UsdLotDialogProps {
  open: boolean;
  cardName: string;
  /** The lot being corrected; null buys a new one. */
  lot: UnifiedLot | null;
  /** Card picker shown above the fields (the "Comprar saldo" flow). */
  picker?: ReactNode;
  onClose: () => void;
  /** Saves; resolves to an error message, or null when it worked. */
  onSave: (value: UsdLotFormValue) => Promise<string | null>;
}

export function UsdLotDialog({ open, cardName, lot, picker, onClose, onSave }: UsdLotDialogProps) {
  return (
    <Dialog open={open} onOpenChange={(next) => (next ? undefined : onClose())}>
      <DialogContent>
        {open ? <UsdLotForm key={lot?.id ?? "new"} cardName={cardName} lot={lot} picker={picker} onClose={onClose} onSave={onSave} /> : null}
      </DialogContent>
    </Dialog>
  );
}

function UsdLotForm({ cardName, lot, picker, onClose, onSave }: Omit<UsdLotDialogProps, "open">) {
  const t = useTranslations("CupInventory");
  const [amount, setAmount] = useState(lot ? String(lot.amount) : "");
  const [usdtPaid, setUsdtPaid] = useState(lot ? String(lot.usdtPaid) : "");
  const [discount, setDiscount] = useState("");
  const [note, setNote] = useState(lot?.note ?? "");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  // Live preview of the USDT the discount implies (only while the USDT field is empty: a typed USDT figure wins).
  const amountValue = parseUsdNumber(amount);
  const percent = discount.trim() === "" ? null : parsePercent(discount);
  const preview = usdtPaid.trim() === "" && amountValue !== null && percent !== null ? discountToUsdtPaid(amountValue, percent) : null;

  async function submit(event: FormEvent) {
    event.preventDefault();
    const result = validateUsdLotForm({ amount, usdtPaid, discount, note });
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
        <DialogTitle>{lot ? t("usdLotForm.titleEdit", { card: cardName }) : t("usdLotForm.titleNew", { card: cardName })}</DialogTitle>
      </DialogHeader>
      {picker}
      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="usd-lot-amount">{t("usdLotForm.amount")}</Label>
          <Input id="usd-lot-amount" value={amount} inputMode="decimal" onChange={(e) => setAmount(e.target.value)} autoFocus />
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="usd-lot-usdt">{t("usdLotForm.usdtPaid")}</Label>
          <Input id="usd-lot-usdt" value={usdtPaid} inputMode="decimal" onChange={(e) => setUsdtPaid(e.target.value)} />
        </div>
      </div>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="usd-lot-discount">{t("usdLotForm.discount")}</Label>
        <Input id="usd-lot-discount" value={discount} onChange={(e) => setDiscount(e.target.value)} />
        <p className="text-muted-foreground text-xs">{t("usdLotForm.discountHint")}</p>
        {preview !== null ? <p className="text-foreground text-sm font-medium tabular-nums">{t("usdLotForm.preview", { usdt: formatUsd(preview) })}</p> : null}
      </div>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="usd-lot-note">{t("lotForm.note")}</Label>
        <Input id="usd-lot-note" value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} />
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
