// Pure shaping of a financial close into the series of the Cierres profit charts. No I/O, no rendering.

import { marginPct } from "@/components/resumen/financial-close-format";
import { shortDayLabel } from "./periods";
import type { FinancialClose } from "./read-model";

export interface DayProfitPoint {
  day: string;
  label: string;
  retorno: number;
  operations: number;
}

export interface ServiceProfitPoint {
  service: string;
  facturado: number;
  invertido: number;
  retorno: number;
  /** One-decimal percentage, or null when nothing was billed (same rule as the table). */
  margin: string | null;
  operations: number;
}

/** One point per day of the period, oldest first. */
export function profitByDaySeries(byDay: FinancialClose["byDay"]): DayProfitPoint[] {
  return [...byDay]
    .sort((a, b) => a.day.localeCompare(b.day))
    .map((d) => ({ day: d.day, label: shortDayLabel(d.day), retorno: d.retornoGyd, operations: d.operations }));
}

/** A single day is not a trend and no days is no data: the chart stays out. */
export function showDayChart(series: DayProfitPoint[]): boolean {
  return series.length > 1;
}

/** Highest profit first; ties by service name so the order never flickers between renders. */
export function profitByServiceSeries(byService: FinancialClose["byService"]): ServiceProfitPoint[] {
  return byService
    .map((s) => ({
      service: s.service,
      facturado: s.facturadoGyd,
      invertido: s.invertidoGyd,
      retorno: s.retornoGyd,
      margin: marginPct(s.facturadoGyd, s.retornoGyd),
      operations: s.operations,
    }))
    .sort((a, b) => b.retorno - a.retorno || a.service.localeCompare(b.service));
}

/** One bar is nothing to compare. */
export function showServiceChart(series: ServiceProfitPoint[]): boolean {
  return series.length > 1;
}
