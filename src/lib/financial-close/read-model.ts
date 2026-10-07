// ============================================================
// Pure mapping of `crm_cierre_financiero` (migration 121) into the
// typed, camelCase shape the /resumen financial close renders. No I/O.
// Postgres numerics can arrive as strings, so every money field goes
// through `toNumber`.
// ============================================================

import type { DateRange } from "./periods";

type Num = number | string;

interface RpcAggregate {
  operaciones: Num;
  facturado_gyd: Num;
  invertido_gyd: Num;
  retorno_gyd: Num;
}

/** Where a ledger row came from: a bot operation, or a line typed in the Calculator (migration 228). */
export type CloseEntrySource = "completed_operation" | "manual";

interface RpcEntry {
  id: string;
  operation_id: string | null;
  /** Absent in payloads from before migration 228: those rows are all bot operations. */
  source?: CloseEntrySource;
  dia: string;
  completed_at: string | null;
  customer_name: string | null;
  service: string;
  amount: Num;
  amount_currency: string;
  cup_rate: Num | null;
  cup_global_rate: Num | null;
  usdt_buy_gyd: Num | null;
  usdt_sell_gyd: Num | null;
  rate_version_id: string | null;
  facturado_gyd: Num | null;
  invertido_gyd: Num | null;
  retorno_gyd: Num | null;
  delivery_mode: string | null;
  actor_user_id: string | null;
  actor_name: string | null;
}

interface RpcExcludedEntry extends RpcEntry {
  status: "void" | "verified_pending";
  void_reason: string | null;
  voided_at: string | null;
  missing_inputs: string[] | null;
}

/** Raw jsonb returned by `crm_cierre_financiero`. */
export interface FinancialCloseRpc {
  desde: string;
  hasta: string;
  zona: string;
  totales: RpcAggregate;
  por_servicio: (RpcAggregate & { service: string })[];
  por_dia: (RpcAggregate & { dia: string })[];
  detalle: RpcEntry[];
  excluidas: RpcExcludedEntry[];
}

export interface CloseAggregate {
  operations: number;
  facturadoGyd: number;
  invertidoGyd: number;
  retornoGyd: number;
}

export interface CloseEntry {
  id: string;
  operationId: string | null;
  source: CloseEntrySource;
  day: string;
  completedAt: string | null;
  customerName: string | null;
  service: string;
  amount: number;
  amountCurrency: string;
  cupRate: number | null;
  cupGlobalRate: number | null;
  usdtBuyGyd: number | null;
  usdtSellGyd: number | null;
  rateVersionId: string | null;
  facturadoGyd: number | null;
  invertidoGyd: number | null;
  retornoGyd: number | null;
  deliveryMode: string | null;
  actorUserId: string | null;
  actorName: string | null;
}

export interface ExcludedEntry extends CloseEntry {
  status: "void" | "verified_pending";
  voidReason: string | null;
  voidedAt: string | null;
  missingInputs: string[];
}

export interface FinancialClose {
  range: DateRange;
  timeZone: string;
  totals: CloseAggregate;
  byService: (CloseAggregate & { service: string })[];
  byDay: (CloseAggregate & { day: string })[];
  detail: CloseEntry[];
  excluded: ExcludedEntry[];
}

function toNumber(value: Num): number {
  return typeof value === "number" ? value : Number(value);
}

function toNullableNumber(value: Num | null): number | null {
  return value === null || value === undefined ? null : toNumber(value);
}

function mapAggregate(row: RpcAggregate): CloseAggregate {
  return {
    operations: toNumber(row.operaciones),
    facturadoGyd: toNumber(row.facturado_gyd),
    invertidoGyd: toNumber(row.invertido_gyd),
    retornoGyd: toNumber(row.retorno_gyd),
  };
}

function mapEntry(row: RpcEntry): CloseEntry {
  return {
    id: row.id,
    operationId: row.operation_id,
    source: row.source ?? "completed_operation",
    day: row.dia,
    completedAt: row.completed_at,
    customerName: row.customer_name,
    service: row.service,
    amount: toNumber(row.amount),
    amountCurrency: row.amount_currency,
    cupRate: toNullableNumber(row.cup_rate),
    cupGlobalRate: toNullableNumber(row.cup_global_rate),
    usdtBuyGyd: toNullableNumber(row.usdt_buy_gyd),
    usdtSellGyd: toNullableNumber(row.usdt_sell_gyd),
    rateVersionId: row.rate_version_id,
    facturadoGyd: toNullableNumber(row.facturado_gyd),
    invertidoGyd: toNullableNumber(row.invertido_gyd),
    retornoGyd: toNullableNumber(row.retorno_gyd),
    deliveryMode: row.delivery_mode,
    actorUserId: row.actor_user_id,
    actorName: row.actor_name,
  };
}

export function mapFinancialClose(raw: FinancialCloseRpc): FinancialClose {
  return {
    range: { desde: raw.desde, hasta: raw.hasta },
    timeZone: raw.zona,
    totals: mapAggregate(raw.totales),
    byService: (raw.por_servicio ?? []).map((row) => ({ service: row.service, ...mapAggregate(row) })),
    byDay: (raw.por_dia ?? []).map((row) => ({ day: row.dia, ...mapAggregate(row) })),
    detail: (raw.detalle ?? []).map(mapEntry),
    excluded: (raw.excluidas ?? []).map((row) => ({
      ...mapEntry(row),
      status: row.status,
      voidReason: row.void_reason,
      voidedAt: row.voided_at,
      missingInputs: row.missing_inputs ?? [],
    })),
  };
}
