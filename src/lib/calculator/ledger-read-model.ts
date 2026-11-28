// ============================================================
// Pure mapping from the calculator ledger's flat DB rows
// (`remittance_calculator_entries`, `calculator_rate_versions`) into the
// HTTP API's typed, camelCase payloads. No I/O — every function here is a
// straight row -> payload transform, unit-tested in isolation from the
// routes that call it.
// ============================================================

import { mapEntryRateSnapshot, type EntryRateSnapshot, type EntryRateSnapshotRow } from "./entry-rates";

/** Column list matching `LedgerEntryRow` exactly — kept next to the type
 *  it feeds so a schema change can't update one without the other. Every
 *  caller that queries `remittance_calculator_entries` for a row destined
 *  for `mapLedgerEntry` should select this, not hand-roll its own list. */
export const LEDGER_ENTRY_COLUMNS =
  "id, account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency, facturado_gyd, invertido_gyd, retorno_gyd, cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, cost_gyd, basis_gyd, sale_gyd, rate_version_id, missing_inputs, delivery_mode, voided_at, void_reason, completed_at, created_at";

/** Raw `remittance_calculator_entries` row shape. Numerics may arrive as
 * `number | string` (Postgres numeric columns round-trip through
 * postgres-js/PostgREST as strings), and every column the DB allows NULL
 * on is typed nullable here too. */
export interface LedgerEntryRow extends EntryRateSnapshotRow {
  id: string;
  account_id: string;
  source: "manual" | "completed_operation";
  status: "completed" | "verified_pending" | "void";
  operation_id: string | null;
  entry_date: string;
  customer_name: string | null;
  service: string;
  amount: number | string;
  amount_currency: string;
  facturado_gyd: number | string | null;
  invertido_gyd: number | string | null;
  retorno_gyd: number | string | null;
  cup_global_rate: number | string | null;
  cup_rate: number | string | null;
  usdt_buy_gyd: number | string | null;
  usdt_sell_gyd: number | string | null;
  rate_version_id: string | null;
  missing_inputs: string[] | null;
  delivery_mode: string | null;
  voided_at: string | null;
  void_reason: string | null;
  completed_at: string | null;
  created_at: string;
}

/** camelCase ledger entry payload returned by the calculator HTTP routes. */
export interface LedgerEntry extends Partial<EntryRateSnapshot> {
  id: string;
  operationId: string | null;
  source: "manual" | "completed_operation";
  status: "completed" | "verified_pending" | "void";
  service: string;
  customerName: string | null;
  amount: number;
  amountCurrency: string;
  entryDate: string;
  facturadoGyd: number | null;
  invertidoGyd: number | null;
  retornoGyd: number | null;
  missingRates: string[];
  rateVersionId: string | null;
  deliveryMode: string | null;
  voidedAt: string | null;
  voidReason: string | null;
  completedAt: string | null;
}

/** The calculator service a combo operation feeds (migration 209): billed in GYD,
 *  the deposit is `facturado` and the cost the admin enters is `invertido`. It is
 *  computed in the database, not by the TS formulas, and has no rates. */
export const COMBO_SERVICE = "COMBO";

/** The calculator service a visa extension feeds (migration 213): billed in GYD,
 *  facturado = retorno = the deposit, invertido = 0. Never pending, no rates. */
export const VISA_SERVICE = "VISA";

/** `missing_inputs` entry of a COMBO line whose cost has not been entered yet. */
export const COMBO_COST_MISSING_INPUT = "comboCosto";

export const COMBO_COST_PENDING_MESSAGE = "Falta el costo del combo: anótalo en el panel de la conversación";

type PendingShape = Pick<LedgerEntry, "service" | "status" | "missingRates">;

/** A COMBO line waiting for the cost entered in the conversation panel. */
export function isComboCostPending(entry: PendingShape): boolean {
  return (
    entry.service === COMBO_SERVICE &&
    entry.status === "verified_pending" &&
    entry.missingRates.includes(COMBO_COST_MISSING_INPUT)
  );
}

/** Whether a pending line can be completed by supplying rates
 *  (`crm_resolve_pending_entry`). Never for COMBO or VISA: they have no rates, and the
 *  procedure would ask for USDT ones. RECARGA and SALDO_MOVIL lines can: the procedure has their own branch (migration
 *  223) that prices them with their USDT cost per unit instead of as a USD service. */
export function canResolveWithRates(entry: PendingShape): boolean {
  return entry.status === "verified_pending" && entry.service !== COMBO_SERVICE && entry.service !== VISA_SERVICE;
}

/** What a pending line is waiting for, in the page's words. */
export function pendingReason(entry: PendingShape): string {
  if (isComboCostPending(entry)) return COMBO_COST_PENDING_MESSAGE;
  return entry.missingRates.length ? entry.missingRates.join(", ") : "tasas pendientes";
}

function toNullableNumber(value: number | string | null): number | null {
  if (value === null) return null;
  return typeof value === "number" ? value : Number(value);
}

function toNumber(value: number | string): number {
  return typeof value === "number" ? value : Number(value);
}

/**
 * Maps one ledger row to its API payload. Converts numeric strings to
 * numbers; null stays null throughout (no zero/default substitution).
 *
 * CRITICAL: `missingRates` comes straight from the stored `missing_inputs`
 * column (`?? []`) and is NEVER recomputed against today's rates — a
 * pending entry's missing rates are what was missing when it was fed into
 * the ledger, which is historical fact, not a live projection.
 */
export function mapLedgerEntry(row: LedgerEntryRow): LedgerEntry {
  return {
    id: row.id,
    operationId: row.operation_id,
    source: row.source,
    status: row.status,
    service: row.service,
    customerName: row.customer_name,
    amount: toNumber(row.amount),
    amountCurrency: row.amount_currency,
    entryDate: row.entry_date,
    facturadoGyd: toNullableNumber(row.facturado_gyd),
    invertidoGyd: toNullableNumber(row.invertido_gyd),
    retornoGyd: toNullableNumber(row.retorno_gyd),
    missingRates: row.missing_inputs ?? [],
    rateVersionId: row.rate_version_id,
    deliveryMode: row.delivery_mode,
    voidedAt: row.voided_at,
    voidReason: row.void_reason,
    completedAt: row.completed_at,
    ...mapEntryRateSnapshot(row),
  };
}

/**
 * Sums ledger entries into the account's running totals. Only
 * `status === "completed"` entries contribute: a `verified_pending` row
 * has no financial snapshot yet (rates were missing when it was fed) and a
 * `void` row was reversed — both must count as zero so totals never
 * include unrealized or reversed money.
 */
export function ledgerTotals(entries: LedgerEntry[]): {
  facturadoGyd: number;
  invertidoGyd: number;
  retornoGyd: number;
  count: number;
} {
  return entries.reduce(
    (totals, entry) => {
      if (entry.status !== "completed") return totals;
      return {
        facturadoGyd: totals.facturadoGyd + (entry.facturadoGyd ?? 0),
        invertidoGyd: totals.invertidoGyd + (entry.invertidoGyd ?? 0),
        retornoGyd: totals.retornoGyd + (entry.retornoGyd ?? 0),
        count: totals.count + 1,
      };
    },
    { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 },
  );
}

/** Raw `calculator_rate_versions` row shape. All four rates are nullable
 * with no default — `null` means "not set yet", never 0 or a commercial
 * default. */
export interface RateVersionRow {
  id: string;
  account_id: string;
  cup_global_rate: number | string | null;
  usdt_buy_gyd: number | string | null;
  usdt_sell_gyd: number | string | null;
  usdt_sell_cup: number | string | null;
  /** GYD per US dollar delivered in cash (migration 188). */
  efectivo_usd_gyd?: number | string | null;
  /** Cost of one recharge in USDT (migration 198). */
  recarga_costo_usdt?: number | string | null;
  /** Cost of one package of mobile balance in USDT (migration 223). */
  saldo_costo_usdt?: number | string | null;
  /** Cost of one recharge of the 500 CUP promotion tier in USDT (migration 242; recarga_costo_usdt is the 600 CUP tier). */
  recarga_costo_usdt_500?: number | string | null;
  /** Zelle sale price of the tiers that start at 50, 1,000 and 2,000 USD (migration 216). */
  zelle_sell_gyd?: number | string | null;
  zelle_sell_gyd_1000?: number | string | null;
  zelle_sell_gyd_2000?: number | string | null;
  set_by: string | null;
  effective_at: string;
}

/** camelCase rates payload returned by the calculator HTTP routes. */
export interface CalculatorRates {
  id: string;
  cupGlobalRate: number | null;
  usdtBuyGyd: number | null;
  usdtSellGyd: number | null;
  usdtSellCup: number | null;
  efectivoUsdGyd: number | null;
  recargaCostoUsdt: number | null;
  saldoCostoUsdt: number | null;
  /** Cost of one recharge of the 500 CUP tier (migration 242). */
  recargaCostoUsdt500: number | null;
  zelleSellGyd: number | null;
  zelleSellGyd1000: number | null;
  zelleSellGyd2000: number | null;
  effectiveAt: string;
  setBy: string | null;
}

/**
 * Maps one `calculator_rate_versions` row to its API payload. Converts
 * numeric strings to numbers; a null rate stays null — never substituted
 * with a default (there is no default; the DB column is NULL with no
 * DEFAULT clause).
 */
export function mapRateVersion(row: RateVersionRow): CalculatorRates {
  return {
    id: row.id,
    cupGlobalRate: toNullableNumber(row.cup_global_rate),
    usdtBuyGyd: toNullableNumber(row.usdt_buy_gyd),
    usdtSellGyd: toNullableNumber(row.usdt_sell_gyd),
    usdtSellCup: toNullableNumber(row.usdt_sell_cup),
    efectivoUsdGyd: toNullableNumber(row.efectivo_usd_gyd ?? null),
    recargaCostoUsdt: toNullableNumber(row.recarga_costo_usdt ?? null),
    saldoCostoUsdt: toNullableNumber(row.saldo_costo_usdt ?? null),
    recargaCostoUsdt500: toNullableNumber(row.recarga_costo_usdt_500 ?? null),
    zelleSellGyd: toNullableNumber(row.zelle_sell_gyd ?? null),
    zelleSellGyd1000: toNullableNumber(row.zelle_sell_gyd_1000 ?? null),
    zelleSellGyd2000: toNullableNumber(row.zelle_sell_gyd_2000 ?? null),
    effectiveAt: row.effective_at,
    setBy: row.set_by,
  };
}
