"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import { validateRange, type DateRange, type PeriodKind, type RangeError } from "@/lib/financial-close/periods";

const KINDS: PeriodKind[] = ["day", "week", "month", "range"];

interface PeriodPickerProps {
  kind: PeriodKind;
  range: DateRange;
  onKindChange: (kind: PeriodKind) => void;
  onShift: (step: -1 | 1) => void;
  onToday: () => void;
  onRangeApply: (range: DateRange) => void;
}

/** One row above the figures: period kind, previous/next, today, and the
 *  custom range inputs when "Rango" is picked. */
export function FinancialClosePeriodPicker({
  kind,
  range,
  onKindChange,
  onShift,
  onToday,
  onRangeApply,
}: PeriodPickerProps) {
  const t = useTranslations("Resumen.cierre");
  const [draft, setDraft] = useState<DateRange>(range);
  const [rangeError, setRangeError] = useState<RangeError | null>(null);

  const apply = () => {
    const error = validateRange(draft);
    setRangeError(error);
    if (!error) onRangeApply(draft);
  };

  return (
    <div className="space-y-2 rounded-xl border border-border bg-card p-3">
      <div className="flex flex-wrap items-center gap-2">
        <div className="flex rounded-lg border border-border p-0.5" role="group">
          {KINDS.map((k) => (
            <button
              key={k}
              type="button"
              aria-pressed={kind === k}
              onClick={() => onKindChange(k)}
              className={cn(
                "rounded-md px-3 py-1 text-xs font-medium transition-colors",
                kind === k ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground",
              )}
            >
              {t(`periodo.${k}`)}
            </button>
          ))}
        </div>

        <div className="flex items-center gap-1">
          <Button type="button" variant="outline" size="icon-sm" aria-label={t("anterior")} onClick={() => onShift(-1)}>
            <ChevronLeft />
          </Button>
          <span className="min-w-[11rem] text-center text-sm font-medium tabular-nums text-foreground">
            {range.desde === range.hasta ? range.desde : `${range.desde} → ${range.hasta}`}
          </span>
          <Button type="button" variant="outline" size="icon-sm" aria-label={t("siguiente")} onClick={() => onShift(1)}>
            <ChevronRight />
          </Button>
        </div>

        <Button type="button" variant="ghost" size="sm" onClick={onToday}>
          {t("hoy")}
        </Button>
      </div>

      {kind === "range" && (
        <div className="flex flex-wrap items-end gap-2">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            {t("desde")}
            <Input
              type="date"
              className="w-40"
              value={draft.desde}
              onChange={(e) => setDraft((d) => ({ ...d, desde: e.target.value }))}
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            {t("hasta")}
            <Input
              type="date"
              className="w-40"
              value={draft.hasta}
              onChange={(e) => setDraft((d) => ({ ...d, hasta: e.target.value }))}
            />
          </label>
          <Button type="button" size="sm" onClick={apply}>
            {t("aplicar")}
          </Button>
          {rangeError && (
            <p role="alert" className="text-xs text-destructive">
              {t(`rangoError.${rangeError}`)}
            </p>
          )}
        </div>
      )}
    </div>
  );
}
