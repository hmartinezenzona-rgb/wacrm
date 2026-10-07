/**
 * Archived Calculator weeks (migration 227). A "Limpiar todo" cut stores the manual text and period the client held,
 * the manual totals the client computed, the chat totals computed in SQL and a snapshot of the chat entries shown.
 * This module only translates the stored row (snake_case, jsonb) into the page's shapes; the routes read the table
 * under the caller's own session (RLS: any member of the account).
 */

import type { ChatCalculatorEntry } from "./realtime-entry";

export const WEEK_SUMMARY_COLUMNS = "id,cut_at,period_label,manual_totals,chat_totals";
export const WEEK_COLUMNS = `${WEEK_SUMMARY_COLUMNS},raw_text,entries`;

type Numeric = number | string | null | undefined;

interface TotalsJson {
  facturado_gyd?: Numeric;
  invertido_gyd?: Numeric;
  retorno_gyd?: Numeric;
  count?: Numeric;
}

interface ArchivedEntryJson {
  id: string;
  operation_id: string;
  service: string;
  customer_name: string | null;
  amount: Numeric;
  amount_currency: string;
  entry_date: string;
  facturado_gyd: Numeric;
  invertido_gyd: Numeric;
  retorno_gyd: Numeric;
}

export interface CalculatorWeekRow {
  id: string;
  cut_at: string;
  period_label: string;
  manual_totals: TotalsJson | null;
  chat_totals: TotalsJson | null;
  raw_text?: string;
  entries?: ArchivedEntryJson[] | null;
}

export interface WeekTotals {
  facturadoGyd: number;
  invertidoGyd: number;
  retornoGyd: number;
}

export interface CalculatorWeekSummary {
  id: string;
  cutAt: string;
  periodo: string;
  manualTotals: WeekTotals;
  chatTotals: WeekTotals & { count: number };
}

export interface CalculatorWeek extends CalculatorWeekSummary {
  rawText: string;
  entries: ChatCalculatorEntry[];
}

function num(value: Numeric): number {
  if (value === null || value === undefined || value === "") return 0;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function nullableNum(value: Numeric): number | null {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function totals(json: TotalsJson | null | undefined): WeekTotals {
  return {
    facturadoGyd: num(json?.facturado_gyd),
    invertidoGyd: num(json?.invertido_gyd),
    retornoGyd: num(json?.retorno_gyd),
  };
}

export function mapWeekSummary(row: CalculatorWeekRow): CalculatorWeekSummary {
  return {
    id: row.id,
    cutAt: row.cut_at,
    periodo: row.period_label,
    manualTotals: totals(row.manual_totals),
    chatTotals: { count: num(row.chat_totals?.count), ...totals(row.chat_totals) },
  };
}

export function mapWeek(row: CalculatorWeekRow): CalculatorWeek {
  return {
    ...mapWeekSummary(row),
    rawText: row.raw_text ?? "",
    entries: (row.entries ?? []).map((entry) => ({
      id: entry.id,
      operationId: entry.operation_id,
      status: "completed" as const,
      service: entry.service,
      customerName: entry.customer_name,
      amount: num(entry.amount),
      amountCurrency: entry.amount_currency,
      entryDate: entry.entry_date,
      facturadoGyd: nullableNum(entry.facturado_gyd),
      invertidoGyd: nullableNum(entry.invertido_gyd),
      retornoGyd: nullableNum(entry.retorno_gyd),
      missingRates: [],
    })),
  };
}
