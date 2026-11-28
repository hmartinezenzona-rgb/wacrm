// ============================================================
// Period arithmetic for the financial close (Finanzas > Cierres).
//
// Every date here is a Guyana business day as a plain "YYYY-MM-DD"
// string — the same day `crm_cierre_financiero` (migration 121) groups
// by. The arithmetic runs on UTC midnights so the viewer's browser
// timezone never moves a boundary.
// ============================================================

export type PeriodKind = "day" | "week" | "month" | "range";

export interface DateRange {
  desde: string;
  hasta: string;
}

/** Same cap as the RPC: 366 days inclusive (one leap year). */
export const MAX_RANGE_DAYS = 366;

export const BUSINESS_TIME_ZONE = "America/Guyana";

const DAY_MS = 86_400_000;
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

function toUtc(day: string): Date {
  return new Date(`${day}T00:00:00Z`);
}

function toDay(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function addDays(day: string, days: number): string {
  return toDay(new Date(toUtc(day).getTime() + days * DAY_MS));
}

function daysBetween(desde: string, hasta: string): number {
  return Math.round((toUtc(hasta).getTime() - toUtc(desde).getTime()) / DAY_MS);
}

function isValidDay(day: string): boolean {
  if (!ISO_DAY.test(day)) return false;
  const parsed = toUtc(day);
  return !Number.isNaN(parsed.getTime()) && toDay(parsed) === day;
}

/** Today's calendar day in Guyana, whatever the browser's timezone. */
export function guyanaToday(now: Date = new Date()): string {
  // en-CA formats as YYYY-MM-DD.
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: BUSINESS_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

function monthRange(year: number, monthIndex: number): DateRange {
  const first = new Date(Date.UTC(year, monthIndex, 1));
  const last = new Date(Date.UTC(year, monthIndex + 1, 0));
  return { desde: toDay(first), hasta: toDay(last) };
}

/** The day, Monday–Sunday week or calendar month that contains `day`.
 *  `range` has no natural shape, so it collapses to that single day. */
export function periodRange(kind: PeriodKind, day: string): DateRange {
  if (kind === "week") {
    // getUTCDay: Sunday = 0. Monday-based offset: Monday = 0 … Sunday = 6.
    const offset = (toUtc(day).getUTCDay() + 6) % 7;
    const desde = addDays(day, -offset);
    return { desde, hasta: addDays(desde, 6) };
  }
  if (kind === "month") {
    const date = toUtc(day);
    return monthRange(date.getUTCFullYear(), date.getUTCMonth());
  }
  return { desde: day, hasta: day };
}

/** The previous (`step` = -1) or next (`step` = 1) period of the same kind.
 *  A custom range moves by its own length. */
export function shiftPeriod(kind: PeriodKind, range: DateRange, step: -1 | 1): DateRange {
  if (kind === "month") {
    const date = toUtc(range.desde);
    return monthRange(date.getUTCFullYear(), date.getUTCMonth() + step);
  }
  const length =
    kind === "day" ? 1 : kind === "week" ? 7 : daysBetween(range.desde, range.hasta) + 1;
  return { desde: addDays(range.desde, step * length), hasta: addDays(range.hasta, step * length) };
}

export type RangeError = "missing" | "invalid" | "reversed" | "too_long";

/** Mirrors the RPC's 22023 checks so the UI can explain before asking. */
export function validateRange(range: DateRange): RangeError | null {
  if (!range.desde || !range.hasta) return "missing";
  if (!isValidDay(range.desde) || !isValidDay(range.hasta)) return "invalid";
  const days = daysBetween(range.desde, range.hasta);
  if (days < 0) return "reversed";
  if (days + 1 > MAX_RANGE_DAYS) return "too_long";
  return null;
}

/** HH:mm of an instant in Guyana time — the clock the business lives on. */
export function guyanaTime(iso: string | null): string {
  if (!iso) return "—";
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: BUSINESS_TIME_ZONE,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(iso));
}

// Fixed Spanish names instead of Intl("es"): ICU versions disagree on
// abbreviations ("sep" vs "sept"), and a label must not change with the
// server or browser it happens to run on.
const MONTHS = [
  "enero", "febrero", "marzo", "abril", "mayo", "junio",
  "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
];
const MONTHS_SHORT = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];
const WEEKDAYS = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"];

function parts(day: string) {
  const date = toUtc(day);
  return { d: date.getUTCDate(), m: date.getUTCMonth(), y: date.getUTCFullYear(), wd: date.getUTCDay() };
}

/** "1 sep" — for chart axes. */
export function shortDayLabel(day: string): string {
  const { d, m } = parts(day);
  return `${d} ${MONTHS_SHORT[m]}`;
}

/** The period in words: "jueves 24 sep 2026", "Semana del 21 al 27 sep 2026",
 *  "septiembre 2026", "10 sep – 15 sep 2026". */
export function periodLabel(kind: PeriodKind, range: DateRange): string {
  const a = parts(range.desde);
  const b = parts(range.hasta);
  if (kind === "day" || range.desde === range.hasta) {
    return `${WEEKDAYS[a.wd]} ${a.d} ${MONTHS_SHORT[a.m]} ${a.y}`;
  }
  if (kind === "month") return `${MONTHS[a.m]} ${a.y}`;
  if (kind === "week") {
    const from = a.y !== b.y ? `${a.d} ${MONTHS_SHORT[a.m]} ${a.y}` : a.m !== b.m ? `${a.d} ${MONTHS_SHORT[a.m]}` : `${a.d}`;
    return `Semana del ${from} al ${b.d} ${MONTHS_SHORT[b.m]} ${b.y}`;
  }
  const from = a.y !== b.y ? `${a.d} ${MONTHS_SHORT[a.m]} ${a.y}` : `${a.d} ${MONTHS_SHORT[a.m]}`;
  return `${from} – ${b.d} ${MONTHS_SHORT[b.m]} ${b.y}`;
}

/** Whether "next period" still lands on a day the business has reached. */
export function canShiftForward(kind: PeriodKind, range: DateRange, today: string): boolean {
  return shiftPeriod(kind, range, 1).desde <= today;
}
