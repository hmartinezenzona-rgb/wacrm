/**
 * Pure mapping for the calculadora page's live "Operaciones del chat" feed
 * (B4.2 — the calculator updates in real time when a remesa completes, no
 * page refresh). This is the raw `remittance_calculator_entries` row (as a
 * Supabase Realtime `postgres_changes` payload carries it) -> the page's
 * `ChatCalculatorEntry` UI shape, mirroring `chatOperationPayload` in
 * `src/app/api/calculadora/route.ts` exactly (same fields, same
 * `source = 'completed_operation'` / `status <> 'void'` filter) so the
 * live feed and the initial `GET /api/calculadora` load never disagree
 * about which rows belong in the table.
 *
 * No Supabase client, no React — the hook (`src/hooks/use-calculator-
 * entries-realtime.ts`) owns the subscription; this module only owns the
 * translation, so it's testable without mocking a channel.
 */

import { mapEntryRateSnapshot, type EntryRateSnapshot, type EntryRateSnapshotRow } from "./entry-rates";

export interface CalculatorEntryRealtimeRow extends EntryRateSnapshotRow {
  id: string;
  /** Null for a manual entry (migration 228). */
  operation_id: string | null;
  status: string;
  service: string;
  customer_name: string | null;
  amount: number | string;
  amount_currency: string;
  entry_date: string;
  facturado_gyd: number | string | null;
  invertido_gyd: number | string | null;
  retorno_gyd: number | string | null;
  missing_inputs: string[] | null;
  source: string;
  /** Present on a realtime payload (the whole row); the weekly cut compares it with the cut. */
  completed_at?: string | null;
  /** Present on a realtime payload (the whole row); a manual entry's registration moment, compared with the cut. */
  created_at?: string | null;
  /** Manual entries only (migration 228): the line as typed, which carries the rates the operation was quoted with. */
  raw_line?: string | null;
}

export interface ChatCalculatorEntry extends Partial<EntryRateSnapshot> {
  id: string;
  /** Null for a manual entry (migration 228). */
  operationId: string | null;
  /** 'manual' rows were typed in the Calculator; 'completed_operation' rows were fed by the bot. */
  source: "completed_operation" | "manual";
  status: "completed" | "verified_pending";
  service: string;
  customerName: string | null;
  amount: number;
  amountCurrency: string;
  entryDate: string;
  facturadoGyd: number | null;
  invertidoGyd: number | null;
  retornoGyd: number | null;
  missingRates: string[];
  /** Manual entries only: the line as typed ("• Michel 50 Zelle (238/260)"); Editar reads the quoted rates from it. */
  rawLine?: string | null;
}

export type CalculatorEntryRealtimeEventType = "INSERT" | "UPDATE" | "DELETE";

function toNullableNumber(value: number | string | null): number | null {
  if (value === null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

/**
 * `null` when the row isn't one the Calculator's table ever shows -- a row that is neither a chat-fed nor a manual entry
 * (`source`), or a voided one (`status = 'void'`) -- exactly mirroring the GET route's own
 * `calculator_current_entries` filter, so a live event can never show a row the initial load would have excluded
 * (or hide one it would have shown).
 */
export function mapRealtimeCalculatorEntry(
  row: CalculatorEntryRealtimeRow,
): ChatCalculatorEntry | null {
  if (row.source !== "completed_operation" && row.source !== "manual") return null;
  if (row.status !== "completed" && row.status !== "verified_pending") return null;

  return {
    id: row.id,
    operationId: row.operation_id,
    source: row.source,
    status: row.status,
    service: row.service,
    customerName: row.customer_name,
    amount: Number(row.amount),
    amountCurrency: row.amount_currency,
    entryDate: row.entry_date,
    facturadoGyd: toNullableNumber(row.facturado_gyd),
    invertidoGyd: toNullableNumber(row.invertido_gyd),
    retornoGyd: toNullableNumber(row.retorno_gyd),
    missingRates: row.missing_inputs ?? [],
    ...mapEntryRateSnapshot(row),
    ...(row.source === "manual" ? { rawLine: row.raw_line ?? null } : {}),
  };
}

/**
 * Adds an entry the page does not hold yet. The list is newest day first (the GET's order): the new entry goes before the
 * ones of its day or older. An entry already in the list is left alone (the same row can arrive from the request that
 * created it and from the live channel).
 */
export function insertCalculatorEntry(entries: ChatCalculatorEntry[], entry: ChatCalculatorEntry): ChatCalculatorEntry[] {
  if (entries.some((existing) => existing.id === entry.id)) return entries;
  const day = entry.entryDate.slice(0, 10);
  const at = entries.findIndex((existing) => existing.entryDate.slice(0, 10) <= day);
  if (at === -1) return [...entries, entry];
  return [...entries.slice(0, at), entry, ...entries.slice(at)];
}

function isArchivedByCut(row: CalculatorEntryRealtimeRow, cutAt: string | null): boolean {
  if (!cutAt || row.status !== "completed") return false;
  // A manual entry is dated on the day typed (its completed_at is midday of that day), so what places it before or after the
  // cut is the moment it was registered.
  const moment = row.source === "manual" ? row.created_at : row.completed_at;
  if (!moment) return false;
  const completed = Date.parse(moment);
  const cut = Date.parse(cutAt);
  return Number.isFinite(completed) && Number.isFinite(cut) && completed <= cut;
}

/**
 * Folds one `postgres_changes` event into the page's existing
 * `chatEntries` array — no refetch involved. An entry that now qualifies
 * (a fresh INSERT, or an UPDATE that resolved its missing rates) is
 * upserted by id; one that stops qualifying (voided, or a DELETE) is
 * dropped. An existing row's position is kept on update, so nothing jumps
 * around the list; a genuinely new row goes before the entries of its day or
 * older — the initial load's `entry_date desc, created_at desc` order, so a
 * manual entry typed for an earlier day lands under the newer ones.
 */
export function applyCalculatorEntryRealtimeEvent(
  entries: ChatCalculatorEntry[],
  eventType: CalculatorEntryRealtimeEventType,
  newRow: CalculatorEntryRealtimeRow | null,
  oldRow: { id?: string } | null,
  cutAt: string | null = null,
): ChatCalculatorEntry[] {
  if (eventType === "DELETE") {
    const id = oldRow?.id;
    if (!id) return entries;
    return entries.filter((entry) => entry.id !== id);
  }

  if (!newRow) return entries;

  const mapped = mapRealtimeCalculatorEntry(newRow);
  const existingIndex = entries.findIndex((entry) => entry.id === newRow.id);

  if (!mapped) {
    return existingIndex === -1 ? entries : entries.filter((entry) => entry.id !== newRow.id);
  }

  if (existingIndex === -1) {
    // Weekly cut (227): a completed entry not on the page that was completed before the latest cut was archived with
    // that week, so it must not reappear. A pending entry is never archived, and an entry already shown keeps updating
    // (a pending line resolved after the cut stays in the new week).
    if (isArchivedByCut(newRow, cutAt)) return entries;
    return insertCalculatorEntry(entries, mapped);
  }

  const next = entries.slice();
  next[existingIndex] = mapped;
  return next;
}
