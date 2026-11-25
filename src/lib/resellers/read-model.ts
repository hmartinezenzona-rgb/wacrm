// ============================================================
// Pure mapping from the reseller totals RPC jsonb payloads
// (snake_case) into the panel's typed camelCase read model. No I/O.
//
// Migration 398 re-pointed the five 397 RPCs additively: the period line is
// now `deposits_gyd` (verified reseller deposits) + `operations_gyd`
// (historical operations created before the cutover) = `counted_gyd`, plus
// `adjustments_gyd` = `total_gyd`. The 397 keys are kept, so a payload that
// predates 398 still maps: absent deposit keys default to zero.
//
// Numeric columns arrive inside jsonb either as JSON numbers or, when
// PostgREST serializes them from a numeric builtin, as decimal strings;
// `num` coerces both so the panel always reads numbers.
// ============================================================

export interface ResellerTotals {
  /** Verified reseller deposits in the period (398). */
  depositsGyd: number;
  depositsCount: number;
  /** The RPC's `operations_gyd`; post-398 this is historical operations only. */
  operationsGyd: number;
  /** Explicit name for `operationsGyd`: operations created before the cutover. */
  historicalOperationsGyd: number;
  operationsCount: number;
  operationsMissingAmount: number;
  adjustmentsGyd: number;
  /** Deposits + historical operations (the RPC's `counted_gyd`). */
  countedGyd: number;
  totalGyd: number;
}

export interface GrandTotal {
  depositsGyd: number;
  depositsCount: number;
  operationsGyd: number;
  historicalOperationsGyd: number;
  adjustmentsGyd: number;
  countedGyd: number;
  totalGyd: number;
  resellers: number;
}

export interface ResellerSummary extends ResellerTotals {
  contactId: string;
  name: string | null;
  phone: string;
  /** Latest reset marker; null means the first period (all time). */
  periodStart: string | null;
  adjustmentsCount: number;
}

export interface ResellerSummaryRead {
  grand: GrandTotal;
  resellers: ResellerSummary[];
}

export interface ResellerAdjustment {
  id: string;
  amountGyd: number;
  reason: string | null;
  actorName: string | null;
  createdAt: string;
}

export interface ResellerPeriod {
  resetId: string;
  start: string | null;
  end: string;
  depositsGyd: number;
  depositsCount: number;
  operationsGyd: number;
  historicalOperationsGyd: number;
  countedGyd: number;
  adjustmentsGyd: number;
  totalGyd: number;
  closedTotalGyd: number;
  closedDepositsGyd: number;
  batchId: string | null;
  resetByName: string | null;
  reason: string | null;
}

export interface ResellerCurrentPeriod extends ResellerTotals {
  periodStart: string | null;
  adjustmentsCount: number;
  adjustments: ResellerAdjustment[];
}

export interface ResellerDetail {
  contactId: string;
  name: string | null;
  phone: string;
  isReseller: boolean;
  /** Pending (unverified) reseller receipt claims; never counted in the total. */
  pendingClaims: number;
  current: ResellerCurrentPeriod;
  /** Newest first, at most 100 (the RPC limit). */
  periods: ResellerPeriod[];
}

export interface ResellerAdjustmentResult {
  adjustmentId: string;
  contactId: string;
  amountGyd: number;
  createdAt: string;
  totalBeforeGyd: number;
  totalAfterGyd: number;
}

export interface ResellerResetResult {
  resetId: string;
  contactId: string;
  resetAt: string;
  closed: {
    depositsGyd: number;
    operationsGyd: number;
    historicalOperationsGyd: number;
    adjustmentsGyd: number;
    countedGyd: number;
    totalGyd: number;
  };
}

export interface ResellerBatchReset {
  resetId: string;
  contactId: string;
  totalGyd: number;
}

export interface ResellerBatchResult {
  batchId: string;
  resetAt: string;
  /** Markers actually written; zero-total resellers are skipped. */
  count: number;
  grandTotalGyd: number;
  resets: ResellerBatchReset[];
}

function obj(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function list(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function num(value: unknown): number {
  if (typeof value === "number") return Number.isFinite(value) ? value : 0;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function nullableStr(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function mapTotals(row: Record<string, unknown>): ResellerTotals {
  const operationsGyd = num(row.operations_gyd);
  return {
    depositsGyd: num(row.deposits_gyd),
    depositsCount: num(row.deposits_count),
    operationsGyd,
    historicalOperationsGyd: operationsGyd,
    operationsCount: num(row.operations_count),
    operationsMissingAmount: num(row.operations_missing_amount),
    adjustmentsGyd: num(row.adjustments_gyd),
    countedGyd: num(row.counted_gyd),
    totalGyd: num(row.total_gyd),
  };
}

export function mapResellerSummaryRead(payload: unknown): ResellerSummaryRead {
  const root = obj(payload);
  const grand = obj(root.grand);
  const grandOperationsGyd = num(grand.operations_gyd);
  return {
    grand: {
      depositsGyd: num(grand.deposits_gyd),
      depositsCount: num(grand.deposits_count),
      operationsGyd: grandOperationsGyd,
      historicalOperationsGyd: grandOperationsGyd,
      adjustmentsGyd: num(grand.adjustments_gyd),
      countedGyd: num(grand.counted_gyd),
      totalGyd: num(grand.total_gyd),
      resellers: num(grand.resellers),
    },
    resellers: list(root.resellers).map((entry) => {
      const row = obj(entry);
      return {
        contactId: str(row.contact_id),
        name: nullableStr(row.name),
        phone: str(row.phone),
        periodStart: nullableStr(row.period_start),
        ...mapTotals(row),
        adjustmentsCount: num(row.adjustments_count),
      };
    }),
  };
}

export function mapResellerDetail(payload: unknown): ResellerDetail {
  const root = obj(payload);
  const current = obj(root.current);
  return {
    contactId: str(root.contact_id),
    name: nullableStr(root.name),
    phone: str(root.phone),
    isReseller: root.is_reseller === true,
    pendingClaims: num(root.pending_claims),
    current: {
      periodStart: nullableStr(current.period_start),
      ...mapTotals(current),
      adjustmentsCount: num(current.adjustments_count),
      adjustments: list(current.adjustments).map((entry) => {
        const row = obj(entry);
        return {
          id: str(row.id),
          amountGyd: num(row.amount_gyd),
          reason: nullableStr(row.reason),
          actorName: nullableStr(row.actor_name),
          createdAt: str(row.created_at),
        };
      }),
    },
    periods: list(root.periods).map((entry) => {
      const row = obj(entry);
      const operationsGyd = num(row.operations_gyd);
      return {
        resetId: str(row.reset_id),
        start: nullableStr(row.start),
        end: str(row.end),
        depositsGyd: num(row.deposits_gyd),
        depositsCount: num(row.deposits_count),
        operationsGyd,
        historicalOperationsGyd: operationsGyd,
        countedGyd: num(row.counted_gyd),
        adjustmentsGyd: num(row.adjustments_gyd),
        totalGyd: num(row.total_gyd),
        closedTotalGyd: num(row.closed_total_gyd),
        closedDepositsGyd: num(row.closed_deposits_gyd),
        batchId: nullableStr(row.batch_id),
        resetByName: nullableStr(row.reset_by_name),
        reason: nullableStr(row.reason),
      };
    }),
  };
}

export function mapAdjustmentResult(payload: unknown): ResellerAdjustmentResult {
  const row = obj(payload);
  return {
    adjustmentId: str(row.adjustment_id),
    contactId: str(row.contact_id),
    amountGyd: num(row.amount_gyd),
    createdAt: str(row.created_at),
    totalBeforeGyd: num(row.total_before_gyd),
    totalAfterGyd: num(row.total_after_gyd),
  };
}

export function mapResetResult(payload: unknown): ResellerResetResult {
  const row = obj(payload);
  const closed = obj(row.closed);
  const operationsGyd = num(closed.operations_gyd);
  return {
    resetId: str(row.reset_id),
    contactId: str(row.contact_id),
    resetAt: str(row.reset_at),
    closed: {
      depositsGyd: num(closed.deposits_gyd),
      operationsGyd,
      historicalOperationsGyd: operationsGyd,
      adjustmentsGyd: num(closed.adjustments_gyd),
      countedGyd: num(closed.counted_gyd),
      totalGyd: num(closed.total_gyd),
    },
  };
}

export function mapBatchResult(payload: unknown): ResellerBatchResult {
  const row = obj(payload);
  return {
    batchId: str(row.batch_id),
    resetAt: str(row.reset_at),
    count: num(row.count),
    grandTotalGyd: num(row.grand_total_gyd),
    resets: list(row.resets).map((entry) => {
      const marker = obj(entry);
      return {
        resetId: str(marker.reset_id),
        contactId: str(marker.contact_id),
        totalGyd: num(marker.total_gyd),
      };
    }),
  };
}
