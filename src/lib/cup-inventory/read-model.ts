// Read model of the CUP inventory: the report RPC (`crm_inventario_cup`, migration 239) speaks snake_case jsonb whose
// numerics may arrive as numbers or strings; the app works with camelCase numbers.

export interface InventoryLot {
  id: string;
  amountCup: number;
  remainingCup: number;
  rateCupPerUsdt: number;
  loadedAt: string;
  note: string | null;
  /** True while nothing was taken from the lot: only then can it be corrected or deleted. */
  editable: boolean;
  /** Nothing left on the lot (migration 256 lists used-up lots too, as history). */
  exhausted: boolean;
  /** True when a balance adjustment touched the lot. */
  adjusted: boolean;
  /** Net CUP taken off the lot by adjustments (negative = given back). */
  adjustmentNetCup: number;
}

export type ConsumptionKind = "operacion" | "manual" | "ajuste";

/** One movement of CUP on a lot, today (Cuba day): a completed operation, a manual line, or a balance adjustment (can be negative). */
export interface InventoryConsumption {
  id: string;
  consumedAt: string;
  amountCup: number;
  lotId: string;
  lotRateCupPerUsdt: number;
  operationId: string | null;
  entryId: string | null;
  /** 'completed_operation' (chat) or 'manual'; null when the entry is unknown. */
  source: string | null;
  customerName: string | null;
  kind: ConsumptionKind;
  /** Why the owner adjusted the balance (kind 'ajuste' only). */
  reason: string | null;
}

export interface InventoryCard {
  id: string;
  name: string;
  last4: string | null;
  priority: number;
  active: boolean;
  dailyLimitCup: number;
  balanceCup: number;
  usedTodayCup: number;
  remainingLimitTodayCup: number;
  /** FIFO: oldest first. */
  lots: InventoryLot[];
  /** Today's movements (Cuba day), newest first. */
  consumptionsToday: InventoryConsumption[];
}

export interface InventoryReport {
  /** The current Cuba day (America/Havana), yyyy-mm-dd. */
  cubaDay: string | null;
  cards: InventoryCard[];
}

type Row = Record<string, unknown>;

function num(value: unknown): number {
  return Number(value ?? 0);
}

export function mapLot(row: Row): InventoryLot {
  return {
    id: String(row.id),
    amountCup: num(row.amount_cup),
    remainingCup: num(row.remaining_cup),
    rateCupPerUsdt: num(row.rate_cup_per_usdt),
    loadedAt: String(row.loaded_at),
    note: (row.note as string | null | undefined) ?? null,
    editable: row.editable === true,
    exhausted: row.agotado === undefined ? num(row.remaining_cup) === 0 : row.agotado === true,
    adjusted: row.adjusted === true,
    adjustmentNetCup: num(row.adjustment_net_cup),
  };
}

export function mapConsumption(row: Row): InventoryConsumption {
  return {
    id: String(row.id),
    consumedAt: String(row.consumed_at),
    amountCup: num(row.amount_cup),
    lotId: String(row.lot_id),
    lotRateCupPerUsdt: num(row.lot_rate_cup_per_usdt),
    operationId: (row.operation_id as string | null | undefined) ?? null,
    entryId: (row.entry_id as string | null | undefined) ?? null,
    source: (row.source as string | null | undefined) ?? null,
    customerName: (row.customer_name as string | null | undefined) ?? null,
    kind: row.kind === "ajuste" || row.kind === "manual" ? row.kind : "operacion",
    reason: (row.reason as string | null | undefined) ?? null,
  };
}

export function mapCard(row: Row): InventoryCard {
  return {
    id: String(row.id),
    name: String(row.name),
    last4: (row.last4 as string | null | undefined) ?? null,
    priority: num(row.priority),
    active: row.active !== false,
    dailyLimitCup: num(row.daily_limit_cup),
    balanceCup: num(row.balance_cup),
    usedTodayCup: num(row.used_today_cup),
    remainingLimitTodayCup: num(row.remaining_limit_today_cup),
    lots: Array.isArray(row.lots) ? (row.lots as Row[]).map(mapLot) : [],
    consumptionsToday: Array.isArray(row.consumptions_today) ? (row.consumptions_today as Row[]).map(mapConsumption) : [],
  };
}

export function mapReport(payload: unknown): InventoryReport {
  const body = (payload ?? {}) as { cuba_day?: string | null; cards?: Row[] };
  return {
    cubaDay: body.cuba_day ?? null,
    cards: Array.isArray(body.cards) ? body.cards.map(mapCard) : [],
  };
}

/** A `cup_cards` row as the save RPC returns it (no balance, no lots). */
export interface CardRecord {
  id: string;
  name: string;
  last4: string | null;
  priority: number;
  dailyLimitCup: number;
  active: boolean;
}

/** A `cup_lots` row as the load / correct RPCs return it. */
export interface LotRecord {
  id: string;
  cardId: string;
  amountCup: number;
  remainingCup: number;
  rateCupPerUsdt: number;
  loadedAt: string;
  note: string | null;
}

export function mapCardRecord(row: Row): CardRecord {
  return {
    id: String(row.id),
    name: String(row.name),
    last4: (row.last4 as string | null | undefined) ?? null,
    priority: num(row.priority),
    dailyLimitCup: num(row.daily_limit_cup),
    active: row.active !== false,
  };
}

export function mapLotRecord(row: Row): LotRecord {
  return {
    id: String(row.id),
    cardId: String(row.card_id),
    amountCup: num(row.amount_cup),
    remainingCup: num(row.remaining_cup),
    rateCupPerUsdt: num(row.rate_cup_per_usdt),
    loadedAt: String(row.loaded_at),
    note: (row.note as string | null | undefined) ?? null,
  };
}

/** What `crm_ajustar_saldo_cup` returns. Movement amounts keep the ledger sign: positive = taken off the lot, negative = given back. */
export interface BalanceAdjustment {
  cardId: string;
  previousBalanceCup: number;
  newBalanceCup: number;
  movements: Array<{ lotId: string; amountCup: number }>;
}

export function mapBalanceResult(row: Row): BalanceAdjustment {
  return {
    cardId: String(row.card_id),
    previousBalanceCup: num(row.saldo_anterior),
    newBalanceCup: num(row.saldo_nuevo),
    movements: Array.isArray(row.movimientos)
      ? (row.movimientos as Row[]).map((m) => ({ lotId: String(m.lot_id), amountCup: num(m.amount_cup) }))
      : [],
  };
}
