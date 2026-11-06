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
import { validateUsdCardForm } from "@/lib/usd-inventory/forms";
import { SERVICE_ORDER, type CardService, type UnifiedCard } from "@/lib/card-inventory/unify";
import { SELECT_CLASS } from "./card-picker";

/** What the dialog hands back: the limit is daily CUP for a CUP card and monthly USD for Clásica / Tropical. */
export interface ServiceCardFormValue {
  service: CardService;
  name: string;
  last4: string;
  limit: number;
  active: boolean;
}

interface ServiceCardDialogProps {
  open: boolean;
  /** The Clásica / Tropical card being edited; null creates a card of any service. */
  card: UnifiedCard | null;
  onClose: () => void;
  /** Saves; resolves to an error message, or null when it worked. */
  onSave: (value: ServiceCardFormValue) => Promise<string | null>;
}

const DEFAULT_LIMIT: Record<CardService, string> = { CUP: "120000", CLASICA: "5000", TROPICAL: "5000" };

export function ServiceCardDialog({ open, card, onClose, onSave }: ServiceCardDialogProps) {
  return (
    <Dialog open={open} onOpenChange={(next) => (next ? undefined : onClose())}>
      <DialogContent>{open ? <ServiceCardForm key={card?.key ?? "new"} card={card} onClose={onClose} onSave={onSave} /> : null}</DialogContent>
    </Dialog>
  );
}

function ServiceCardForm({ card, onClose, onSave }: Omit<ServiceCardDialogProps, "open">) {
  const t = useTranslations("CupInventory");
  const [service, setService] = useState<CardService>(card?.service ?? "CUP");
  const [name, setName] = useState(card?.name ?? "");
  const [last4, setLast4] = useState(card?.last4 ?? "");
  const [limit, setLimit] = useState(card ? String(card.limit) : DEFAULT_LIMIT.CUP);
  const [active, setActive] = useState(card?.active ?? true);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  function changeService(next: CardService) {
    setService(next);
    setLimit(DEFAULT_LIMIT[next]);
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    const result =
      service === "CUP"
        ? validateCardForm({ name, last4, dailyLimit: limit })
        : validateUsdCardForm({ service, name, last4, monthlyLimit: limit });
    if (!result.ok) {
      setError(t(`errors.${result.errorKey}`));
      return;
    }
    const value = result.value;
    setSaving(true);
    setError(null);
    const failure = await onSave({
      service,
      name: value.name,
      last4: value.last4,
      limit: "dailyLimitCup" in value ? value.dailyLimitCup : value.monthlyLimitUsd,
      active,
    });
    setSaving(false);
    if (failure) setError(failure);
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4">
      <DialogHeader>
        <DialogTitle>{card ? t("cardForm.titleEdit") : t("cardForm.titleNew")}</DialogTitle>
        <DialogDescription>{service === "CUP" ? t("cubaDayHint") : t("newCardForm.monthlyHint")}</DialogDescription>
      </DialogHeader>
      {card ? null : (
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="new-card-service">{t("newCardForm.service")}</Label>
          <select id="new-card-service" className={SELECT_CLASS} value={service} onChange={(e) => changeService(e.target.value as CardService)}>
            {SERVICE_ORDER.map((option) => (
              <option key={option} value={option}>
                {t(`services.${option}`)}
              </option>
            ))}
          </select>
        </div>
      )}
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="new-card-name">{t("cardForm.name")}</Label>
        <Input id="new-card-name" value={name} maxLength={60} onChange={(e) => setName(e.target.value)} autoFocus />
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="new-card-last4">{t("cardForm.last4")}</Label>
          <Input id="new-card-last4" value={last4} inputMode="numeric" maxLength={4} onChange={(e) => setLast4(e.target.value)} />
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="new-card-limit">{service === "CUP" ? t("newCardForm.dailyLimit") : t("newCardForm.monthlyLimit")}</Label>
          <Input id="new-card-limit" value={limit} inputMode="decimal" onChange={(e) => setLimit(e.target.value)} />
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
