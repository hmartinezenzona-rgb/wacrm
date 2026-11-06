"use client";

import { useTranslations } from "next-intl";
import { formatCup } from "@/lib/cup-inventory/format";
import type { CardFilter, ServiceTotal } from "@/lib/card-inventory/unify";
import { cn } from "@/lib/utils";
import { SERVICE_CHIP_CLASS } from "./card-row";

/** One box per service: balance in its own currency and the card count. A service without balance is red. */
export function TotalsStrip({ totals }: { totals: ServiceTotal[] }) {
  const t = useTranslations("CupInventory");
  return (
    <ul aria-label={t("totals.label")} className="grid grid-cols-1 gap-3 sm:grid-cols-3">
      {totals.map((total) => (
        <li
          key={total.service}
          data-total={total.service}
          className={cn(
            "bg-card flex flex-col gap-1 rounded-xl border p-3",
            total.empty ? "border-red-400 dark:border-red-500/70" : "border-border",
          )}
        >
          <span className={cn("w-fit rounded-full px-2 py-0.5 text-xs font-medium", SERVICE_CHIP_CLASS[total.service])}>{t(`services.${total.service}`)}</span>
          <span className="text-foreground text-xl font-semibold tabular-nums">
            {formatCup(total.balance)} <span className="text-muted-foreground text-sm font-normal">{total.unit}</span>
          </span>
          <span className="text-muted-foreground flex flex-wrap items-center gap-x-2 text-xs">
            {t("totals.cards", { n: total.cards })}
            {total.empty ? <strong className="font-semibold text-red-600 dark:text-red-400">{t("totals.noBalance")}</strong> : null}
          </span>
        </li>
      ))}
    </ul>
  );
}

const FILTERS: CardFilter[] = ["all", "CUP", "CLASICA", "TROPICAL"];

/** Service filter: toggle buttons, one pressed at a time, each at least 44px tall. */
export function FilterChips({ value, onChange }: { value: CardFilter; onChange: (filter: CardFilter) => void }) {
  const t = useTranslations("CupInventory");
  return (
    <div role="group" aria-label={t("filters.label")} className="flex flex-wrap gap-2">
      {FILTERS.map((filter) => (
        <button
          key={filter}
          type="button"
          aria-pressed={value === filter}
          onClick={() => onChange(filter)}
          className={cn(
            "min-h-11 rounded-full border px-4 text-sm font-medium transition-colors",
            value === filter ? "border-primary bg-primary text-primary-foreground" : "border-border bg-card text-foreground hover:bg-muted",
          )}
        >
          {t(`filters.${filter}`)}
        </button>
      ))}
    </div>
  );
}
