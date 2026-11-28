"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { validateCardForm } from "@/lib/cup-inventory/forms";
import type { InventoryCard } from "@/lib/cup-inventory/read-model";

export interface CardFormValue {
  name: string;
  last4: string;
  dailyLimitCup: number;
  active: boolean;
}

interface CardDialogProps {
  open: boolean;
  /** The card being edited; null creates a new one. */
  card: InventoryCard | null;
  onClose: () => void;
  /** Saves; resolves to an error message, or null when it worked. */
  onSave: (value: CardFormValue) => Promise<string | null>;
}

export function CardDialog({ open, card, onClose, onSave }: CardDialogProps) {
  return (
    <Dialog open={open} onOpenChange={(next) => (next ? undefined : onClose())}>
      <DialogContent>{open ? <CardForm key={card?.id ?? "new"} card={card} onClose={onClose} onSave={onSave} /> : null}</DialogContent>
    </Dialog>
  );
}

function CardForm({ card, onClose, onSave }: Omit<CardDialogProps, "open">) {
  const t = useTranslations("CupInventory");
  const [name, setName] = useState(card?.name ?? "");
  const [last4, setLast4] = useState(card?.last4 ?? "");
  const [dailyLimit, setDailyLimit] = useState(String(card?.dailyLimitCup ?? 120000));
  const [active, setActive] = useState(card?.active ?? true);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function submit(event: FormEvent) {
    event.preventDefault();
    const result = validateCardForm({ name, last4, dailyLimit });
    if (!result.ok) {
      setError(t(`errors.${result.errorKey}`));
      return;
    }
    setSaving(true);
    setError(null);
    const failure = await onSave({ ...result.value, active });
    setSaving(false);
    if (failure) setError(failure);
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4">
      <DialogHeader>
        <DialogTitle>{card ? t("cardForm.titleEdit") : t("cardForm.titleNew")}</DialogTitle>
        <DialogDescription>{t("cubaDayHint")}</DialogDescription>
      </DialogHeader>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="cup-card-name">{t("cardForm.name")}</Label>
        <Input id="cup-card-name" value={name} maxLength={60} onChange={(e) => setName(e.target.value)} autoFocus />
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="cup-card-last4">{t("cardForm.last4")}</Label>
          <Input id="cup-card-last4" value={last4} inputMode="numeric" maxLength={4} onChange={(e) => setLast4(e.target.value)} />
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="cup-card-limit">{t("cardForm.dailyLimit")}</Label>
          <Input id="cup-card-limit" value={dailyLimit} inputMode="decimal" onChange={(e) => setDailyLimit(e.target.value)} />
        </div>
      </div>
      {card ? (
        <Label>
          <Checkbox checked={active} onCheckedChange={(checked) => setActive(checked === true)} />
          {t("cardForm.active")}
        </Label>
      ) : null}
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
