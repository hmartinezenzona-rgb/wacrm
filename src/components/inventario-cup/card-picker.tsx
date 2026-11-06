"use client";

import { useTranslations } from "next-intl";
import { Label } from "@/components/ui/label";
import type { UnifiedCard } from "@/lib/card-inventory/unify";

/** Native select styled like the Input component; the dialogs use it for service and card pickers. */
export const SELECT_CLASS =
  "border-input bg-background text-foreground focus-visible:ring-ring/50 h-11 w-full rounded-lg border px-2.5 text-sm outline-none focus-visible:ring-3";

interface CardPickerProps {
  cards: UnifiedCard[];
  /** `UnifiedCard.key` of the chosen card. */
  value: string;
  onChange: (key: string) => void;
}

/** Lists the active cards of every service ("Clásica · Clásica A ···· 4321") so a purchase can pick where the balance goes. */
export function CardPicker({ cards, value, onChange }: CardPickerProps) {
  const t = useTranslations("CupInventory");
  return (
    <div className="flex flex-col gap-1.5">
      <Label htmlFor="lot-card-picker">{t("picker.label")}</Label>
      <select id="lot-card-picker" className={SELECT_CLASS} value={value} onChange={(e) => onChange(e.target.value)}>
        {cards.map((card) => (
          <option key={card.key} value={card.key}>
            {t(`services.${card.service}`)} · {card.name}
            {card.last4 ? ` ···· ${card.last4}` : ""}
          </option>
        ))}
      </select>
    </div>
  );
}
