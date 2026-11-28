// Read model of the USD card inventory: `crm_inventario_usd` (migration 355) speaks snake_case jsonb whose numerics may
// arrive as numbers or strings; the app works with camelCase numbers.

export type UsdService = "CLASICA" | "TROPICAL";
export const USD_SERVICES: readonly UsdService[] = ["CLASICA", "TROPICAL"];

export interface UsdLot {
  id: string;
  amountUsd: number;
  remainingUsd: number;
  usdtPaid: number;
  /** USD received per USDT paid (1.05 = a 5% discount, 1 = "1x1"). */
  usdPerUsdt: number;
  loadedAt: string;
  note: string | null;
  /** True while nothing was taken from the lot: only then can it be corrected or deleted. */
  editable: boolean;
  exhausted: boolean;
  adjusted: boolean;
  adjustmentNetUsd: number;
}

export type UsdConsumptionKind = "operacion" | "manual" | "ajuste";

export interface UsdConsumption {
  id: string;
  consumedAt: string;
  amountUsd: number;
  lotId: string;
  lotUsdPerUsdt: number;
  operationId: string | null;
  entryId: string | null;
  source: string | null;
  customerName: string | null;
  kind: UsdConsumptionKind;
  reason: string | null;
}

export interface UsdCard {
  id: string;
  service: UsdService;
  name: string;
  last4: string | null;
  priority: number;
  active: boolean;
  monthlyLimitUsd: number;
  balanceUsd: number;
  usedThisMonthUsd: number;
  remainingMonthUsd: number;
  /** FIFO: oldest first. */
  lots: UsdLot[];
  /** This Cuba month's movements, newest first. */
  consumptionsMonth: UsdConsumption[];
}

export interface UsdServiceTotals {
  cards: number;
  balanceUsd: number;
  monthlyLimitUsd: number;
  usedThisMonthUsd: number;
  remainingMonthUsd: number;
}

export interface UsdReport {
  /** First day of the current Cuba month (America/Havana), yyyy-mm-dd. */
  cubaMonth: string | null;
  cards: UsdCard[];
  totals: Record<UsdService, UsdServiceTotals>;
}

type Row = Record<string, unknown>;

function num(value: unknown): number {
  return Number(value ?? 0);
}

function str(value: unknown): string | null {
  return (value as string | null | undefined) ?? null;
}

function isService(value: unknown): value is UsdService {
  return value === "CLASICA" || value === "TROPICAL";
}

export function mapUsdLot(row: Row): UsdLot {
  return {
    id: String(row.id),
    amountUsd: num(row.amount_usd),
    remainingUsd: num(row.remaining_usd),
    usdtPaid: num(row.usdt_paid),
    usdPerUsdt: num(row.usd_per_usdt),
    loadedAt: String(row.loaded_at),
    note: str(row.note),
    editable: row.editable === true,
    exhausted: row.agotado === undefined ? num(row.remaining_usd) === 0 : row.agotado === true,
    adjusted: row.adjusted === true,
    adjustmentNetUsd: num(row.adjustment_net_usd),
  };
}

export function mapUsdConsumption(row: Row): UsdConsumption {
  return {
    id: String(row.id),
    consumedAt: String(row.consumed_at),
    amountUsd: num(row.amount_usd),
    lotId: String(row.lot_id),
    lotUsdPerUsdt: num(row.lot_usd_per_usdt),
    operationId: str(row.operation_id),
    entryId: str(row.entry_id),
    source: str(row.source),
    customerName: str(row.customer_name),
    kind: row.kind === "ajuste" || row.kind === "manual" ? row.kind : "operacion",
    reason: str(row.reason),
  };
}

function mapUsdCard(row: Row & { service: UsdService }): UsdCard {
  return {
    id: String(row.id),
    service: row.service,
    name: String(row.name),
    last4: str(row.last4),
    priority: num(row.priority),
    active: row.active !== false,
    monthlyLimitUsd: num(row.monthly_limit_usd),
    balanceUsd: num(row.balance_usd),
    usedThisMonthUsd: num(row.used_this_month_usd),
    remainingMonthUsd: num(row.remaining_month_usd),
    lots: Array.isArray(row.lots) ? (row.lots as Row[]).map(mapUsdLot) : [],
    consumptionsMonth: Array.isArray(row.consumptions_month) ? (row.consumptions_month as Row[]).map(mapUsdConsumption) : [],
  };
}

function mapTotals(row: Row | undefined): UsdServiceTotals {
  return {
    cards: num(row?.cards),
    balanceUsd: num(row?.balance_usd),
    monthlyLimitUsd: num(row?.monthly_limit_usd),
    usedThisMonthUsd: num(row?.used_this_month_usd),
    remainingMonthUsd: num(row?.remaining_month_usd),
  };
}

export function mapUsdReport(payload: unknown): UsdReport {
  const body = (payload ?? {}) as { cuba_month?: string | null; cards?: Row[]; totals?: Record<string, Row> };
  const cards = Array.isArray(body.cards)
    ? body.cards.filter((row): row is Row & { service: UsdService } => isService(row.service)).map(mapUsdCard)
    : [];
  return {
    cubaMonth: body.cuba_month ?? null,
    cards,
    totals: { CLASICA: mapTotals(body.totals?.CLASICA), TROPICAL: mapTotals(body.totals?.TROPICAL) },
  };
}

/** A `usd_cards` row as the save RPC returns it (no balance, no lots). */
export interface UsdCardRecord {
  id: string;
  service: UsdService;
  name: string;
  last4: string | null;
  priority: number;
  monthlyLimitUsd: number;
  active: boolean;
}

/** A `usd_lots` row as the load / correct RPCs return it. */
export interface UsdLotRecord {
  id: string;
  cardId: string;
  amountUsd: number;
  remainingUsd: number;
  usdtPaid: number;
  usdPerUsdt: number;
  loadedAt: string;
  note: string | null;
}

export function mapUsdCardRecord(row: Row): UsdCardRecord {
  return {
    id: String(row.id),
    service: row.service as UsdService,
    name: String(row.name),
    last4: str(row.last4),
    priority: num(row.priority),
    monthlyLimitUsd: num(row.monthly_limit_usd),
    active: row.active !== false,
  };
}

export function mapUsdLotRecord(row: Row): UsdLotRecord {
  return {
    id: String(row.id),
    cardId: String(row.card_id),
    amountUsd: num(row.amount_usd),
    remainingUsd: num(row.remaining_usd),
    usdtPaid: num(row.usdt_paid),
    usdPerUsdt: num(row.usd_per_usdt),
    loadedAt: String(row.loaded_at),
    note: str(row.note),
  };
}

/** What `crm_ajustar_saldo_usd` returns. Movement amounts keep the ledger sign: positive = taken off the lot, negative = given back. */
export interface UsdBalanceAdjustment {
  cardId: string;
  previousBalanceUsd: number;
  newBalanceUsd: number;
  movements: Array<{ lotId: string; amountUsd: number }>;
}

export function mapUsdBalanceResult(row: Row): UsdBalanceAdjustment {
  return {
    cardId: String(row.card_id),
    previousBalanceUsd: num(row.saldo_anterior),
    newBalanceUsd: num(row.saldo_nuevo),
    movements: Array.isArray(row.movimientos)
      ? (row.movimientos as Row[]).map((m) => ({ lotId: String(m.lot_id), amountUsd: num(m.amount_usd) }))
      : [],
  };
}
