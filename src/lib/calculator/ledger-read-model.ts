// ============================================================
// Pure mapping from the calculator ledger's flat DB rows
// (`remittance_calculator_entries`, `calculator_rate_versions`) into the
// HTTP API's typed, camelCase payloads. No I/O — every function here is a
// straight row -> payload transform, unit-tested in isolation from the
// routes that call it.
// ============================================================

/** Column list matching `LedgerEntryRow` exactly — kept next to the type
 *  it feeds so a schema change can't update one without the other. Every
 *  caller that queries `remittance_calculator_entries` for a row destined
 *  for `mapLedgerEntry` should select this, not hand-roll its own list. */
export const LEDGER_ENTRY_COLUMNS =
  "id, account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency, facturado_gyd, invertido_gyd, retorno_gyd, cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id, missing_inputs, delivery_mode, voided_at, void_reason, completed_at, created_at";

/** Raw `remittance_calculator_entries` row shape. Numerics may arrive as
 * `number | string` (Postgres numeric columns round-trip through
 * postgres-js/PostgREST as strings), and every column the DB allows NULL
 * on is typed nullable here too. */
export interface LedgerEntryRow {
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
export interface LedgerEntry {
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
    effectiveAt: row.effective_at,
    setBy: row.set_by,
  };
}
