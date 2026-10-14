/**
 * Pure helpers for editing the INVESTMENT rates of one completed ledger entry (migration 236,
 * `crm_corregir_tasas_entrada_calculadora`). `recomputeInvestment` mirrors that function's formulas so the Editar
 * form can preview what the database will store; the database remains the authority.
 *
 *   CUP                              (amount / cup_rate) * usdt_buy_gyd
 *   RECARGA                          amount * cost_gyd * usdt_buy_gyd
 *   SALDO_MOVIL                      (basis_gyd / sale_gyd) * cost_gyd * usdt_buy_gyd   (amount is saldo units)
 *   ZELLE, MLC, CLASICA, TROPICAL,
 *   USDT, EFECTIVO, DIRECTO          amount * usdt_buy_gyd
 *   COMBO, VISA                      no rates: not editable
 */

type Numeric = number | string | null | undefined;

/** The rates an entry was costed with (the snapshot columns of `remittance_calculator_entries`). */
export interface EntryRateSnapshot {
  /** "Tarifa CUP": CUP per GYD of the customer's price. Never edited here. */
  cupGlobalRate: number | null;
  /** "Venta USDT (CUP)": CUP per USDT of the investment (CUP service; a RECARGA/SALDO_MOVIL line keeps the buy rate here). */
  cupRate: number | null;
  /** "Compra USDT (GYD)". */
  usdtBuyGyd: number | null;
  /** Sale rate of the line. Never edited here. */
  usdtSellGyd: number | null;
  /** USDT cost per recharge / per saldo package (RECARGA, SALDO_MOVIL). */
  costGyd: number | null;
  /** The line's share of the deposit in GYD. */
  basisGyd: number | null;
  /** Package price of a SALDO_MOVIL line. */
  saleGyd: number | null;
}

/** The snake_case columns `mapEntryRateSnapshot` reads (all optional: a row may not carry them). */
export interface EntryRateSnapshotRow {
  cup_global_rate?: Numeric;
  cup_rate?: Numeric;
  usdt_buy_gyd?: Numeric;
  usdt_sell_gyd?: Numeric;
  cost_gyd?: Numeric;
  basis_gyd?: Numeric;
  sale_gyd?: Numeric;
}

/** Column list to append to a `remittance_calculator_entries` / `calculator_current_entries` select. */
export const ENTRY_RATE_SNAPSHOT_COLUMNS =
  "cup_global_rate,cup_rate,usdt_buy_gyd,usdt_sell_gyd,cost_gyd,basis_gyd,sale_gyd";

function toNullableNumber(value: Numeric): number | null {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

export function mapEntryRateSnapshot(row: EntryRateSnapshotRow): EntryRateSnapshot {
  return {
    cupGlobalRate: toNullableNumber(row.cup_global_rate),
    cupRate: toNullableNumber(row.cup_rate),
    usdtBuyGyd: toNullableNumber(row.usdt_buy_gyd),
    usdtSellGyd: toNullableNumber(row.usdt_sell_gyd),
    costGyd: toNullableNumber(row.cost_gyd),
    basisGyd: toNullableNumber(row.basis_gyd),
    saleGyd: toNullableNumber(row.sale_gyd),
  };
}

/** What `recomputeInvestment` / `canEditEntryRates` need of an entry. */
export interface EntryRateInput {
  source: string;
  status: string;
  service: string;
  amount: number;
  facturadoGyd: number | null;
  cupRate: number | null;
  usdtBuyGyd: number | null;
  costGyd: number | null;
  basisGyd: number | null;
  saleGyd: number | null;
}

const NO_RATES_SERVICES = new Set(["COMBO", "VISA"]);

/**
 * Services a MANUAL row (migration 237) may take rates for: the ones the manual calculator costs with the same plain formula
 * as the ledger (CUP: (amount / cup) * buy; the others: amount * buy). A manual RECARGA / SALDO_MOVIL stores no unit cost,
 * DIRECTO has no investment, and a discounted manual line is refused by the database.
 */
const MANUAL_RATE_SERVICES = new Set(["CUP", "ZELLE", "MLC", "CLASICA", "TROPICAL", "USDT"]);

function hasRates(entry: Pick<EntryRateInput, "source" | "service">): boolean {
  if (NO_RATES_SERVICES.has(entry.service)) return false;
  return entry.source === "manual" ? MANUAL_RATE_SERVICES.has(entry.service) : entry.source === "completed_operation";
}

function isRate(value: number | null | undefined): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 && value < 1e9;
}

/** Which investment rates the admin may change on this entry: a completed chat-fed entry, or a manual one of a plain-formula service. */
export function canEditEntryRates(entry: Pick<EntryRateInput, "source" | "status" | "service">): {
  buy: boolean;
  cup: boolean;
} {
  const editable = entry.status === "completed" && hasRates(entry);
  return { buy: editable, cup: editable && entry.service === "CUP" };
}

/**
 * The invertido / retorno the entry gets with the new rates (an omitted or null rate keeps the stored one), or `null`
 * when the database would refuse it: nothing editable, a rate that is not > 0, a cup_rate on a non-CUP service, or a
 * snapshot without what the service's formula needs.
 */
export function recomputeInvestment(
  entry: EntryRateInput,
  rates: { usdtBuyGyd?: number | null; cupRate?: number | null },
): { invertidoGyd: number; retornoGyd: number } | null {
  if (!hasRates(entry) || entry.facturadoGyd === null) return null;
  if (rates.usdtBuyGyd != null && !isRate(rates.usdtBuyGyd)) return null;
  if (rates.cupRate != null && !isRate(rates.cupRate)) return null;
  if (rates.cupRate != null && entry.service !== "CUP") return null;

  const buy = rates.usdtBuyGyd ?? entry.usdtBuyGyd;
  if (!isRate(buy)) return null;

  let invertidoGyd: number;
  if (entry.service === "CUP") {
    const cup = rates.cupRate ?? entry.cupRate;
    if (!isRate(cup)) return null;
    invertidoGyd = (entry.amount / cup) * buy;
  } else if (entry.service === "RECARGA") {
    if (entry.costGyd === null) return null;
    invertidoGyd = entry.amount * entry.costGyd * buy;
  } else if (entry.service === "SALDO_MOVIL") {
    if (entry.costGyd === null || entry.basisGyd === null || !isRate(entry.saleGyd)) return null;
    const packages = entry.basisGyd / entry.saleGyd;
    if (Math.abs(packages - Math.round(packages)) > 1e-9) return null;
    invertidoGyd = Math.round(packages) * entry.costGyd * buy;
  } else {
    invertidoGyd = entry.amount * buy;
  }

  if (!Number.isFinite(invertidoGyd) || invertidoGyd < 0 || invertidoGyd >= 1e15) return null;
  return { invertidoGyd, retornoGyd: entry.facturadoGyd - invertidoGyd };
}
