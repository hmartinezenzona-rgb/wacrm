// Pure figures of the Finanzas > Semana overview. No I/O, no rendering: the component hands in the entries the page
// already loaded and gets back everything it draws. Only `completed` entries count; a pending, voided or unknown one
// never adds to a total (a pending one only raises the "incomplete lines" warning).

import { guyanaToday } from "@/lib/calculator/manual-entries";

/** The stored per-entry figures the overview reads (a `ChatCalculatorEntry` fits). */
export interface OverviewEntry {
  id: string;
  /** The Guyana business day, as the entries table shows it (the first 10 characters). */
  entryDate: string;
  status: string;
  service: string;
  customerName: string | null;
  facturadoGyd: number | null;
  invertidoGyd: number | null;
  retornoGyd: number | null;
  usdtBuyGyd?: number | null;
  missingRates: string[];
}

/** An archived week's entry (the weeks API keeps no rates or status; every archived entry was completed). */
export interface PreviousWeekEntry {
  entryDate: string;
  facturadoGyd: number | null;
  retornoGyd: number | null;
}

export interface PreviousWeekInput {
  /** Guyana day the previous week started (the cut before it); null when unknown. */
  startDay: string | null;
  entries: PreviousWeekEntry[];
}

const DAY_MS = 86_400_000;
const dayOf = (value: string) => value.slice(0, 10);
const utcMs = (day: string) => Date.parse(`${dayOf(day)}T00:00:00Z`);

export function dayDiff(from: string, to: string): number {
  return Math.round((utcMs(to) - utcMs(from)) / DAY_MS);
}

function addDays(day: string, days: number): string {
  return new Date(utcMs(day) + days * DAY_MS).toISOString().slice(0, 10);
}

/** Monday of the Mon-Sun week the day belongs to. */
export function mondayOf(day: string): string {
  const weekday = new Date(utcMs(day)).getUTCDay();
  return addDays(day, -((weekday + 6) % 7));
}

const isCompleted = (entry: { status: string }) => entry.status === "completed";
const isLive = (entry: { status: string }) => entry.status === "completed" || entry.status === "verified_pending";
const money = (value: number | null | undefined) => value ?? 0;

export function openWeekStart(cutAt: string | null, entries: OverviewEntry[]): { day: string | null; fromCut: boolean } {
  if (cutAt) {
    const cut = new Date(cutAt);
    if (!Number.isNaN(cut.getTime())) return { day: guyanaToday(cut), fromCut: true };
  }
  const days = entries.filter(isLive).map((e) => dayOf(e.entryDate)).sort();
  return { day: days[0] ?? null, fromCut: false };
}

export interface WeekTotals {
  facturado: number;
  invertido: number;
  retorno: number;
  ops: number;
  /** Profit over billed, in percent; null when nothing was billed. */
  margin: number | null;
  /** Billed per operation; null without operations. */
  ticket: number | null;
}

export function weekTotals(entries: OverviewEntry[]): WeekTotals {
  let facturado = 0;
  let invertido = 0;
  let retorno = 0;
  let ops = 0;
  for (const entry of entries) {
    if (!isCompleted(entry)) continue;
    facturado += money(entry.facturadoGyd);
    invertido += money(entry.invertidoGyd);
    retorno += money(entry.retornoGyd);
    ops += 1;
  }
  return {
    facturado,
    invertido,
    retorno,
    ops,
    margin: facturado ? (retorno / facturado) * 100 : null,
    ticket: ops ? facturado / ops : null,
  };
}

/** USDT bought and its average cost, over the entries that carry a buy rate; the cost uses the same entries. */
export function usdtSummary(entries: OverviewEntry[]): { usdt: number; avgCost: number } | null {
  let usdt = 0;
  let invested = 0;
  for (const entry of entries) {
    const rate = entry.usdtBuyGyd;
    if (!isCompleted(entry) || !rate || rate <= 0 || entry.invertidoGyd == null) continue;
    usdt += entry.invertidoGyd / rate;
    invested += entry.invertidoGyd;
  }
  return usdt > 0 ? { usdt, avgCost: invested / usdt } : null;
}

/** Relative change in percent; null when there is no base to compare with. */
export function percentChange(current: number, base: number): number | null {
  return base ? ((current - base) / Math.abs(base)) * 100 : null;
}

export interface DayPoint {
  day: string;
  retorno: number;
  ops: number;
  isToday: boolean;
  /** The best day of the week (the only one that gets a value label). */
  isMax: boolean;
}

/** Monday to Saturday of the week of `today`; entries of other days (Sunday, an older week) are not charted. */
export function profitByDay(entries: OverviewEntry[], today: string): DayPoint[] {
  const monday = mondayOf(today);
  const days: DayPoint[] = Array.from({ length: 6 }, (_, i) => {
    const day = addDays(monday, i);
    return { day, retorno: 0, ops: 0, isToday: day === today, isMax: false };
  });
  for (const entry of entries) {
    if (!isCompleted(entry)) continue;
    const point = days.find((d) => d.day === dayOf(entry.entryDate));
    if (!point) continue;
    point.retorno += money(entry.retornoGyd);
    point.ops += 1;
  }
  const best = Math.max(...days.map((d) => d.retorno));
  if (best > 0) days.find((d) => d.retorno === best)!.isMax = true;
  return days;
}

export interface ServiceRow {
  service: string;
  facturado: number;
  retorno: number;
  ops: number;
  margin: number | null;
}

/** Highest profit first; ties by service key so the order never flickers. */
export function profitByService(entries: OverviewEntry[]): ServiceRow[] {
  const rows = new Map<string, ServiceRow>();
  for (const entry of entries) {
    if (!isCompleted(entry)) continue;
    const row = rows.get(entry.service) ?? { service: entry.service, facturado: 0, retorno: 0, ops: 0, margin: null };
    row.facturado += money(entry.facturadoGyd);
    row.retorno += money(entry.retornoGyd);
    row.ops += 1;
    rows.set(entry.service, row);
  }
  return [...rows.values()]
    .map((row) => ({ ...row, margin: row.facturado ? (row.retorno / row.facturado) * 100 : null }))
    .sort((a, b) => b.retorno - a.retorno || a.service.localeCompare(b.service));
}

export interface ClientRow {
  name: string;
  retorno: number;
  ops: number;
}

/** Top clients by profit. Names are matched ignoring case and surrounding spaces; blank names are left out. */
export function topClients(entries: OverviewEntry[], limit = 5): ClientRow[] {
  const rows = new Map<string, ClientRow>();
  for (const entry of entries) {
    const name = entry.customerName?.trim();
    if (!isCompleted(entry) || !name) continue;
    const key = name.toLocaleLowerCase();
    const row = rows.get(key) ?? { name, retorno: 0, ops: 0 };
    row.retorno += money(entry.retornoGyd);
    row.ops += 1;
    rows.set(key, row);
  }
  return [...rows.values()].sort((a, b) => b.retorno - a.retorno || a.name.localeCompare(b.name)).slice(0, limit);
}

/** Lines the week cannot count yet: waiting for a rate or with rates missing. Voided lines are not lines. */
export function incompleteCount(entries: OverviewEntry[]): number {
  return entries.filter((e) => isLive(e) && (e.status !== "completed" || e.missingRates.length > 0)).length;
}

export interface SemanaOverview {
  empty: boolean;
  startDay: string | null;
  fromCut: boolean;
  today: { day: string; ops: number; facturado: number; retorno: number };
  totals: WeekTotals;
  usdt: { usdt: number; avgCost: number } | null;
  comparison: { profitPct: number | null; facturadoPct: number | null } | null;
  days: DayPoint[];
  services: ServiceRow[];
  clients: ClientRow[];
  incomplete: number;
}

/** The previous week up to the same elapsed day count since its own start. */
function previousAtSamePoint(previous: PreviousWeekInput, elapsedDays: number) {
  const own = previous.entries.map((e) => dayOf(e.entryDate)).sort()[0];
  const start = previous.startDay ?? own;
  if (!start) return null;
  const upTo = previous.entries.filter((e) => dayDiff(start, e.entryDate) <= elapsedDays);
  if (upTo.length === 0) return null;
  return {
    facturado: upTo.reduce((sum, e) => sum + money(e.facturadoGyd), 0),
    retorno: upTo.reduce((sum, e) => sum + money(e.retornoGyd), 0),
  };
}

export function buildSemanaOverview(
  entries: OverviewEntry[],
  cutAt: string | null,
  previous: PreviousWeekInput | null,
  now: Date,
): SemanaOverview {
  const live = entries.filter(isLive);
  const day = guyanaToday(now);
  const { day: startDay, fromCut } = openWeekStart(cutAt, entries);
  const totals = weekTotals(entries);
  const todays = weekTotals(entries.filter((e) => dayOf(e.entryDate) === day));

  let comparison: SemanaOverview["comparison"] = null;
  if (previous && startDay) {
    const base = previousAtSamePoint(previous, Math.max(0, dayDiff(startDay, day)));
    if (base) {
      comparison = {
        profitPct: percentChange(totals.retorno, base.retorno),
        facturadoPct: percentChange(totals.facturado, base.facturado),
      };
    }
  }

  return {
    empty: live.length === 0,
    startDay,
    fromCut,
    today: { day, ops: todays.ops, facturado: todays.facturado, retorno: todays.retorno },
    totals,
    usdt: usdtSummary(entries),
    comparison,
    days: profitByDay(entries, day),
    services: profitByService(entries),
    clients: topClients(entries),
    incomplete: incompleteCount(entries),
  };
}
