// Pure shaping of the archived week summaries into the "Ganancia por semana" line. The summaries already carry the
// manual and chat totals, so the profit of a week is their sum (same sum as the archived-weeks table).

import { shortDayLabel } from "@/lib/financial-close/periods";
import type { CalculatorWeekSummary } from "@/lib/calculator/weeks";
import { cutDate } from "./legacy-calc-format";

/** How many of the latest weeks the line covers. */
export const WEEKS_SHOWN = 12;

export interface WeekProfitPoint {
  id: string;
  /** X axis tick: the cut day, short ("12 oct"). */
  label: string;
  cutDate: string;
  periodo: string;
  facturado: number;
  retorno: number;
}

/** The last {@link WEEKS_SHOWN} weeks by cut time, oldest to newest. */
export function weeklyProfitSeries(weeks: CalculatorWeekSummary[]): WeekProfitPoint[] {
  return [...weeks]
    .sort((a, b) => new Date(a.cutAt).getTime() - new Date(b.cutAt).getTime())
    .slice(-WEEKS_SHOWN)
    .map((w) => {
      const day = cutDate(w.cutAt);
      return {
        id: w.id,
        label: shortDayLabel(day),
        cutDate: day,
        periodo: w.periodo,
        facturado: w.manualTotals.facturadoGyd + w.chatTotals.facturadoGyd,
        retorno: w.manualTotals.retornoGyd + w.chatTotals.retornoGyd,
      };
    });
}

export function showWeekChart(series: WeekProfitPoint[]): boolean {
  return series.length > 1;
}
