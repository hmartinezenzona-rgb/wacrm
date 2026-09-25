"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { createClient } from "@/lib/supabase/client";
import { loadFinancialClose } from "@/lib/financial-close/load";
import {
  guyanaToday,
  periodRange,
  shiftPeriod,
  type DateRange,
  type PeriodKind,
} from "@/lib/financial-close/periods";
import type { FinancialClose } from "@/lib/financial-close/read-model";
import { FinancialClosePeriodPicker } from "./financial-close-period-picker";
import { FinancialCloseSummary } from "./financial-close-summary";
import { FinancialCloseDetail } from "./financial-close-detail";

type LoadResult = { status: "error" } | { status: "loaded"; data: FinancialClose };

/**
 * The financial close on /resumen: what the business billed, invested and
 * earned in a period, read from the calculator ledger through
 * `crm_cierre_financiero` (migration 121). Opens on the current Guyana
 * week; the period is changed with the picker above the figures.
 */
export function FinancialCloseSection() {
  const t = useTranslations("Resumen.cierre");
  const [kind, setKind] = useState<PeriodKind>("week");
  const [range, setRange] = useState<DateRange>(() => periodRange("week", guyanaToday()));
  // Bumped by "Reintentar" to re-run the same range.
  const [attempt, setAttempt] = useState(0);
  // The result is stored with the request it answers; "loading" is simply
  // "no result for the current request yet", so no effect has to reset it.
  const requestKey = `${range.desde}|${range.hasta}|${attempt}`;
  const [result, setResult] = useState<{ key: string; value: LoadResult } | null>(null);

  useEffect(() => {
    let cancelled = false;
    void loadFinancialClose(createClient(), range).then((loaded) => {
      if (cancelled) return;
      setResult({
        key: `${range.desde}|${range.hasta}|${attempt}`,
        value: loaded.ok ? { status: "loaded", data: loaded.data } : { status: "error" },
      });
    });
    return () => {
      cancelled = true;
    };
  }, [range, attempt]);

  const state = result?.key === requestKey ? result.value : { status: "loading" as const };

  const changeKind = useCallback(
    (next: PeriodKind) => {
      setKind(next);
      // Re-anchor on the period being viewed, so "Mes de agosto" → "Día"
      // lands on 1 August, not on today.
      if (next !== "range") setRange(periodRange(next, range.desde));
    },
    [range.desde],
  );

  return (
    <section className="space-y-3">
      <div>
        <h2 className="text-sm font-semibold text-foreground">{t("title")}</h2>
        <p className="text-xs text-muted-foreground">{t("subtitle")}</p>
      </div>

      <FinancialClosePeriodPicker
        // Remount on every period change: the custom-range inputs restart
        // from the period being viewed and any old validation message clears.
        key={`${kind}|${range.desde}|${range.hasta}`}
        kind={kind}
        range={range}
        onKindChange={changeKind}
        onShift={(step) => setRange((current) => shiftPeriod(kind, current, step))}
        onToday={() => setRange(periodRange(kind === "range" ? "day" : kind, guyanaToday()))}
        onRangeApply={setRange}
      />

      {state.status === "loading" && (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-primary" />
        </div>
      )}

      {state.status === "error" && (
        <div className="flex items-center justify-between gap-3 rounded-xl border border-destructive/40 bg-card p-4">
          <p className="text-sm text-destructive">{t("loadError")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => setAttempt((n) => n + 1)}>
            {t("reintentar")}
          </Button>
        </div>
      )}

      {state.status === "loaded" && (
        <>
          <FinancialCloseSummary close={state.data} />
          <FinancialCloseDetail close={state.data} />
        </>
      )}
    </section>
  );
}
