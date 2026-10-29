// Pure figures of the Finanzas > Cierres overview. No I/O, no rendering: the component hands in the archived weeks it
// loaded and gets back everything it draws. Profit, billed and invested of a week are the stored week totals (the same
// sum the archived-weeks table always showed); the dates, operation count, best day and top service come from the
// week's archived entries, every one of which was completed when the week was cut.

import { guyanaToday } from "@/lib/calculator/manual-entries";
import { percentChange } from "./semana-overview";

export type CierresPeriod = "last12" | "thisMonth" | "lastMonth" | "all";

/** The archived entry fields this module reads (a `ChatCalculatorEntry` fits). */
export interface WeekEntryInput {
  entryDate: string;
  service: string;
  facturadoGyd: number | null;
  retornoGyd: number | null;
}

export interface ClosedWeekInput {
  id: string;
  cutAt: string;
  periodo: string;
  facturado: number;
  invertido: number;
  retorno: number;
  /** Null while the week's detail is not loaded (or could not be read). */
  entries: WeekEntryInput[] | null;
}

export interface ClosedWeek {
  id: string;
  cutAt: string;
  name: string;
  /** First entry day (Guyana); null without entries. */
  startDay: string | null;
  /** Last entry day, or the Guyana day of the cut when there are no entries. */
  endDay: string;
  facturado: number;
  invertido: number;
  retorno: number;
  /** Profit over billed, in percent; null when nothing was billed. */
  margin: number | null;
  /** Null when the entries are not known. */
  ops: number | null;
  bestDay: { day: string; retorno: number } | null;
  topService: string | null;
  /** Profit by service, from the entries. */
  serviceProfit: Record<string, number>;
  /** Profit change against the next older archived week; null without a base. */
  vsPrevious: number | null;
}

const dayOf = (value: string) => value.slice(0, 10);
const money = (value: number | null | undefined) => value ?? 0;

function fromEntries(entries: WeekEntryInput[]) {
  const days = new Map<string, number>();
  const serviceProfit: Record<string, number> = {};
  for (const e of entries) {
    const day = dayOf(e.entryDate);
    days.set(day, (days.get(day) ?? 0) + money(e.retornoGyd));
    serviceProfit[e.service] = (serviceProfit[e.service] ?? 0) + money(e.retornoGyd);
  }
  const sortedDays = [...days.keys()].sort();
  // Highest profit; the earliest day wins a tie so the answer never flickers.
  let bestDay: ClosedWeek["bestDay"] = null;
  for (const day of sortedDays) {
    const retorno = days.get(day)!;
    if (!bestDay || retorno > bestDay.retorno) bestDay = { day, retorno };
  }
  let topService: string | null = null;
  for (const service of Object.keys(serviceProfit).sort()) {
    if (topService === null || serviceProfit[service]! > serviceProfit[topService]!) topService = service;
  }
  return { startDay: sortedDays[0] ?? null, endDay: sortedDays[sortedDays.length - 1] ?? null, bestDay, topService, serviceProfit };
}

/** Closed weeks, newest cut first, each with its change against the next older one. */
export function buildClosedWeeks(inputs: ClosedWeekInput[]): ClosedWeek[] {
  const sorted = [...inputs].sort((a, b) => Date.parse(b.cutAt) - Date.parse(a.cutAt));
  const weeks = sorted.map((input): ClosedWeek => {
    const found = input.entries ? fromEntries(input.entries) : null;
    return {
      id: input.id,
      cutAt: input.cutAt,
      name: input.periodo,
      startDay: found?.startDay ?? null,
      endDay: found?.endDay ?? guyanaToday(new Date(input.cutAt)),
      facturado: input.facturado,
      invertido: input.invertido,
      retorno: input.retorno,
      margin: input.facturado ? (input.retorno / input.facturado) * 100 : null,
      ops: input.entries ? input.entries.length : null,
      bestDay: found?.bestDay ?? null,
      topService: found?.topService ?? null,
      serviceProfit: found?.serviceProfit ?? {},
      vsPrevious: null,
    };
  });
  return weeks.map((week, i) => {
    const older = weeks[i + 1];
    return { ...week, vsPrevious: older ? percentChange(week.retorno, older.retorno) : null };
  });
}

function previousMonth(month: string): string {
  const [year, m] = month.split("-").map(Number) as [number, number];
  return m === 1 ? `${year - 1}-12` : `${year}-${String(m - 1).padStart(2, "0")}`;
}

/** `weeks` newest first; `today` is the Guyana day. */
export function filterWeeksByPeriod(weeks: ClosedWeek[], period: CierresPeriod, today: string): ClosedWeek[] {
  const month = today.slice(0, 7);
  switch (period) {
    case "last12":
      return weeks.slice(0, 12);
    case "thisMonth":
      return weeks.filter((w) => w.endDay.startsWith(month));
    case "lastMonth": {
      const last = previousMonth(month);
      return weeks.filter((w) => w.endDay.startsWith(last));
    }
    default:
      return weeks;
  }
}

export interface ServiceShare {
  service: string;
  retorno: number;
  /** Percent of the period's service profit; null when that total is not positive. */
  share: number | null;
}

export interface ChartPoint {
  id: string;
  endDay: string;
  retorno: number;
}

export interface CierresOverview {
  count: number;
  totals: { retorno: number; facturado: number; invertido: number };
  /** Last `weeks` weeks against the `weeks` before them; null with fewer than two weeks or no base. */
  change: { pct: number; weeks: number } | null;
  avgProfit: number | null;
  /** Average operations per week over the weeks whose entries are known. */
  avgOps: number | null;
  best: ClosedWeek | null;
  /** Null unless there are at least two weeks to tell them apart. */
  worst: ClosedWeek | null;
  margin: number | null;
  /** Oldest to newest. */
  chart: ChartPoint[];
  average: number | null;
  services: ServiceShare[];
}

const MAX_COMPARED = 6;

/** `weeks` is the period's weeks, newest first. */
export function buildCierresOverview(weeks: ClosedWeek[]): CierresOverview {
  const count = weeks.length;
  const totals = weeks.reduce(
    (sum, w) => ({ retorno: sum.retorno + w.retorno, facturado: sum.facturado + w.facturado, invertido: sum.invertido + w.invertido }),
    { retorno: 0, facturado: 0, invertido: 0 },
  );

  let change: CierresOverview["change"] = null;
  const compared = Math.min(MAX_COMPARED, Math.floor(count / 2));
  if (compared > 0) {
    const sum = (list: ClosedWeek[]) => list.reduce((acc, w) => acc + w.retorno, 0);
    const pct = percentChange(sum(weeks.slice(0, compared)), sum(weeks.slice(compared, compared * 2)));
    if (pct !== null) change = { pct, weeks: compared };
  }

  const known = weeks.filter((w) => w.ops !== null);
  // Newest wins a tie, so the card names the week the owner remembers.
  const best = weeks.reduce<ClosedWeek | null>((top, w) => (!top || w.retorno > top.retorno ? w : top), null);
  const worst = count < 2 ? null : weeks.reduce<ClosedWeek | null>((low, w) => (!low || w.retorno < low.retorno ? w : low), null);

  const byService = new Map<string, number>();
  for (const w of weeks) for (const [service, retorno] of Object.entries(w.serviceProfit)) byService.set(service, (byService.get(service) ?? 0) + retorno);
  const serviceTotal = [...byService.values()].reduce((a, b) => a + b, 0);
  const services = [...byService.entries()]
    .map(([service, retorno]) => ({ service, retorno, share: serviceTotal > 0 ? (retorno / serviceTotal) * 100 : null }))
    .sort((a, b) => b.retorno - a.retorno || a.service.localeCompare(b.service));

  return {
    count,
    totals,
    change,
    avgProfit: count ? totals.retorno / count : null,
    avgOps: known.length ? known.reduce((acc, w) => acc + (w.ops ?? 0), 0) / known.length : null,
    best,
    worst,
    margin: totals.facturado ? (totals.retorno / totals.facturado) * 100 : null,
    chart: [...weeks].reverse().map((w) => ({ id: w.id, endDay: w.endDay, retorno: w.retorno })),
    average: count ? totals.retorno / count : null,
    services,
  };
}
