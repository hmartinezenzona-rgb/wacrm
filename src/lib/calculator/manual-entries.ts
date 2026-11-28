/**
 * Manual operations as ledger entries (migration 228).
 *
 * The Calculator page parses the text box on the client (`procesarTexto`). "Registrar" sends the lines it could interpret,
 * each with the day it belongs to, to `crm_registrar_entradas_manuales`, which ADDS them to the ledger as rows of the
 * Calculator's one table (source 'manual'); the registered lines then leave the box. Nothing is registered by the autosave.
 *
 * Pure module: date resolution, the mapping from parsed lines to ledger lines, the removal of the registered lines from
 * the text, and the shape check the route runs on what the client sent (the RPC validates again).
 */

import { parsearLinea, procesarTexto, type WebCalculatorOperation } from "./web-calculator";

/** Ledger services a manual line can carry; the same set the add RPC accepts. */
export const MANUAL_SERVICES = [
  "CUP", "ZELLE", "MLC", "TROPICAL", "CLASICA", "USDT", "SALDO_MOVIL", "RECARGA", "DIRECTO",
] as const;
export type ManualService = (typeof MANUAL_SERVICES)[number];

/** The add RPC takes at most this many lines. */
export const MAX_MANUAL_LINES = 500;

export interface ManualEntryLine {
  /** 1-based line number in the text box: which line leaves the box once it is registered. Not sent to the server. */
  line: number;
  /** Guyana business day, YYYY-MM-DD. */
  date: string;
  /** The day header the line sits under, as typed ("Martes 6"); null before any header. */
  dayLabel: string | null;
  customer: string;
  service: ManualService;
  amount: number;
  currency: string;
  facturadoGyd: number;
  invertidoGyd: number;
  retornoGyd: number;
  rawLine: string;
}

// ---------------------------------------------------------------- dates

const GUYANA_DAY = new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/Guyana", year: "numeric", month: "2-digit", day: "2-digit",
});

/** The Guyana business day (YYYY-MM-DD) of an instant. */
export function guyanaToday(now: Date): string {
  return GUYANA_DAY.format(now);
}

const DAY_MS = 86_400_000;
// The document is a weekly record, so a day header is looked for in the last two weeks only; a header that matches
// nothing there (written ahead of time, or a day the month does not have) dates its lines today.
const LOOKBACK_DAYS = 14;

const WEEKDAYS: Record<string, number> = {
  domingo: 0, lunes: 1, martes: 2, miercoles: 3, jueves: 4, viernes: 5, sabado: 6,
};
const MONTHS: Record<string, number> = {
  enero: 1, febrero: 2, marzo: 3, abril: 4, mayo: 5, junio: 6, julio: 7,
  agosto: 8, septiembre: 9, setiembre: 9, octubre: 10, noviembre: 11, diciembre: 12,
};

function normalize(text: string): string {
  return text.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
}

function toMs(day: string): number {
  const [year, month, date] = day.split("-").map(Number);
  return Date.UTC(year!, month! - 1, date!);
}

function fromMs(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/** YYYY-MM-DD when (year, month, day) is a real calendar date, else null. */
function realDate(year: number, month: number, day: number): string | null {
  const ms = Date.UTC(year, month - 1, day);
  const date = new Date(ms);
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  return fromMs(ms);
}

/** The most recent date that is day `day` of `month` (a year chosen so it is not after `today`). */
function recentDayMonth(day: number, month: number, today: string): string | null {
  const thisYear = Number(today.slice(0, 4));
  for (const year of [thisYear, thisYear - 1, thisYear - 2, thisYear - 3, thisYear - 4]) {
    const candidate = realDate(year, month, day);
    if (candidate && candidate <= today) return candidate;
  }
  return null;
}

/**
 * The date a day header stands for, relative to `today` (a Guyana YYYY-MM-DD):
 *  - "Martes 6", "6": the most recent date with that day number (and that weekday, when given) not after today;
 *  - "Lunes 12/10", "6 de octubre": that day and month, in the most recent year not after today;
 *  - "Martes": the most recent such weekday, today included;
 *  - no header, or a header it cannot read: today.
 * Accents and case do not matter.
 */
export function resolveManualDate(header: string | null | undefined, today: string): string {
  if (!header) return today;
  const text = normalize(header);

  const weekdayName = Object.keys(WEEKDAYS).find((name) => new RegExp(`\\b${name}\\b`).test(text));
  const weekday = weekdayName === undefined ? null : WEEKDAYS[weekdayName]!;

  // day/month[/year]
  const slash = /(\d{1,2})\s*[/.-]\s*(\d{1,2})(?:\s*[/.-]\s*(\d{2,4}))?/.exec(text);
  if (slash) {
    const day = Number(slash[1]);
    const month = Number(slash[2]);
    if (slash[3]) {
      const raw = Number(slash[3]);
      const resolved = realDate(slash[3].length === 2 ? 2000 + raw : raw, month, day);
      return resolved && resolved <= today ? resolved : today;
    }
    return recentDayMonth(day, month, today) ?? today;
  }

  // "6 de octubre"
  const named = /(\d{1,2})\s*(?:de\s+)?([a-z]+)/.exec(text);
  const namedMonth = named ? MONTHS[named[2]!] : undefined;
  if (named && namedMonth) return recentDayMonth(Number(named[1]), namedMonth, today) ?? today;

  const number = /\b(\d{1,2})\b/.exec(text);
  if (number) {
    const day = Number(number[1]);
    const todayMs = toMs(today);
    // First the exact match (weekday and number); a mistyped weekday must not move the day, so the number alone wins next.
    for (const needWeekday of weekday === null ? [false] : [true, false]) {
      for (let back = 0; back <= LOOKBACK_DAYS; back += 1) {
        const date = new Date(todayMs - back * DAY_MS);
        if (date.getUTCDate() === day && (!needWeekday || date.getUTCDay() === weekday)) return fromMs(date.getTime());
      }
    }
    return today;
  }

  if (weekday !== null) {
    const todayMs = toMs(today);
    for (let back = 0; back <= 6; back += 1) {
      const date = new Date(todayMs - back * DAY_MS);
      if (date.getUTCDay() === weekday) return fromMs(date.getTime());
    }
  }
  return today;
}

// ---------------------------------------------------------------- mapping

function serviceOf(operation: WebCalculatorOperation): ManualService | null {
  // The direct lines (visa, ext, trabajo, estudiante, trad, combo, pasaje) are the group "TRÁMITES / COMBOS / SERVICIOS".
  if (operation.esDirecto) return "DIRECTO";
  if (operation.tipo === "SALDO MOVIL") return "SALDO_MOVIL";
  return (MANUAL_SERVICES as readonly string[]).includes(operation.tipo) ? (operation.tipo as ManualService) : null;
}

function currencyOf(service: ManualService): string {
  if (service === "CUP") return "CUP";
  if (service === "DIRECTO") return "GYD";
  if (service === "RECARGA" || service === "SALDO_MOVIL") return "REC";
  return "USD";
}

function validFigures(operation: WebCalculatorOperation): boolean {
  return Number.isFinite(operation.monto) && operation.monto > 0
    && Number.isFinite(operation.fact) && operation.fact >= 0
    && Number.isFinite(operation.inv) && operation.inv >= 0
    && Number.isFinite(operation.retorno);
}

export interface ManualEntriesResult {
  lines: ManualEntryLine[];
  /** Lines that stay in the box: not interpreted by the parser, or parsed but not holdable by the ledger (unknown service,
   *  no amount, negative figures). */
  uninterpreted: Array<{ line: number; raw: string }>;
}

/**
 * The ledger lines of a Calculator text: the page's own parse (day headers excluded), each line dated by the header it
 * sits under. Lines the ledger cannot hold are returned apart in `uninterpreted`, never sent.
 */
export function manualEntriesFromText(text: string, cupGlobalRate: number, today: string): ManualEntriesResult {
  const lines: ManualEntryLine[] = [];
  const uninterpreted: ManualEntriesResult["uninterpreted"] = [];

  for (const operation of procesarTexto(text, cupGlobalRate).operations) {
    if ("error" in operation) {
      uninterpreted.push({ line: operation.linea, raw: operation.raw });
      continue;
    }
    const service = serviceOf(operation);
    const customer = operation.cliente.trim();
    if (!service || !customer || customer.length > 240 || !validFigures(operation)) {
      uninterpreted.push({ line: operation.linea, raw: operation.raw });
      continue;
    }
    lines.push({
      line: operation.linea,
      date: resolveManualDate(operation.dia, today),
      dayLabel: operation.dia === "General" ? null : operation.dia,
      customer,
      service,
      amount: operation.monto,
      currency: currencyOf(service),
      facturadoGyd: operation.fact,
      invertidoGyd: operation.inv,
      retornoGyd: operation.retorno,
      rawLine: operation.raw,
    });
  }
  return { lines, uninterpreted };
}

/**
 * The text that remains after the lines numbered `registered` were registered: those lines are removed, and so is a day
 * header that has none of its lines left (a header with no line under it from the start stays). Lines that could not be
 * interpreted stay, with the header they sit under. Blank-line runs left behind collapse; nothing left gives "".
 */
export function removeRegisteredLines(text: string, registered: readonly number[]): string {
  if (registered.length === 0) return text;
  const gone = new Set(registered);
  const lines = text.split("\n");
  const keep = lines.map((_, index) => !gone.has(index + 1));

  let header = -1;
  let removed = 0;
  let remaining = 0;
  const closeGroup = () => {
    if (header >= 0 && removed > 0 && remaining === 0) keep[header] = false;
  };
  lines.forEach((line, index) => {
    const parsed = parsearLinea(line, "General");
    if (!parsed) return;
    if (parsed.esDia) {
      closeGroup();
      header = index;
      removed = 0;
      remaining = 0;
      return;
    }
    if (gone.has(index + 1)) removed += 1;
    else remaining += 1;
  });
  closeGroup();

  const out: string[] = [];
  lines.forEach((line, index) => {
    if (!keep[index]) return;
    const blank = line.trim() === "";
    if (blank && (out.length === 0 || out[out.length - 1]!.trim() === "")) return;
    out.push(line);
  });
  while (out.length > 0 && out[out.length - 1]!.trim() === "") out.pop();
  return out.join("\n");
}

// ---------------------------------------------------------------- route side

/** One line as `crm_registrar_entradas_manuales` takes it. */
export interface ManualEntryRpcLine {
  date: string;
  day_label: string | null;
  customer: string;
  service: ManualService;
  amount: number;
  currency: string;
  facturado_gyd: number;
  invertido_gyd: number;
  retorno_gyd: number;
  raw_line: string | null;
}

const isFinite_ = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

function toRpcLine(input: unknown): ManualEntryRpcLine | null {
  if (typeof input !== "object" || input === null) return null;
  const line = input as Record<string, unknown>;
  if (typeof line.date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(line.date)) return null;
  if (typeof line.customer !== "string" || line.customer.trim() === "") return null;
  if (typeof line.service !== "string" || !(MANUAL_SERVICES as readonly string[]).includes(line.service)) return null;
  if (typeof line.currency !== "string" || line.currency === "") return null;
  if (!isFinite_(line.amount) || line.amount <= 0) return null;
  if (!isFinite_(line.facturadoGyd) || line.facturadoGyd < 0) return null;
  if (!isFinite_(line.invertidoGyd) || line.invertidoGyd < 0) return null;
  if (!isFinite_(line.retornoGyd)) return null;
  if (line.dayLabel !== null && line.dayLabel !== undefined && typeof line.dayLabel !== "string") return null;
  if (line.rawLine !== null && line.rawLine !== undefined && typeof line.rawLine !== "string") return null;
  return {
    date: line.date,
    day_label: (line.dayLabel as string | null | undefined) ?? null,
    customer: line.customer,
    service: line.service as ManualService,
    amount: line.amount,
    currency: line.currency,
    facturado_gyd: line.facturadoGyd,
    invertido_gyd: line.invertidoGyd,
    retorno_gyd: line.retornoGyd,
    raw_line: (line.rawLine as string | null | undefined) ?? null,
  };
}

/** Checks what the client sent as the lines to register and maps it to the RPC's shape; the RPC validates again. */
export function parseManualLines(input: unknown):
  | { ok: true; lines: ManualEntryRpcLine[] }
  | { ok: false } {
  if (!Array.isArray(input) || input.length === 0 || input.length > MAX_MANUAL_LINES) return { ok: false };
  const lines: ManualEntryRpcLine[] = [];
  for (const item of input) {
    const line = toRpcLine(item);
    if (!line) return { ok: false };
    lines.push(line);
  }
  return { ok: true, lines };
}
