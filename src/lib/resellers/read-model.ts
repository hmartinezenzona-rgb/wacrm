// ============================================================
// Pure mapping from the 397 reseller totals RPC jsonb payloads
// (snake_case) into the panel's typed camelCase read model. No I/O.
//
// Numeric columns arrive inside jsonb either as JSON numbers or, when
// PostgREST serializes them from a numeric builtin, as decimal strings;
// `num` coerces both so the panel always reads numbers.
// ============================================================

export interface ResellerTotals {
  operationsGyd: number;
  operationsCount: number;
  operationsMissingAmount: number;
  adjustmentsGyd: number;
  totalGyd: number;
}

export interface GrandTotal {
  operationsGyd: number;
  adjustmentsGyd: number;
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
  operationsGyd: number;
  adjustmentsGyd: number;
  totalGyd: number;
  closedTotalGyd: number;
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
  closed: { operationsGyd: number; adjustmentsGyd: number; totalGyd: number };
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
  return {
    operationsGyd: num(row.operations_gyd),
    operationsCount: num(row.operations_count),
    operationsMissingAmount: num(row.operations_missing_amount),
    adjustmentsGyd: num(row.adjustments_gyd),
    totalGyd: num(row.total_gyd),
  };
}

export function mapResellerSummaryRead(payload: unknown): ResellerSummaryRead {
  const root = obj(payload);
  const grand = obj(root.grand);
  return {
    grand: {
      operationsGyd: num(grand.operations_gyd),
      adjustmentsGyd: num(grand.adjustments_gyd),
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
      return {
        resetId: str(row.reset_id),
        start: nullableStr(row.start),
        end: str(row.end),
        operationsGyd: num(row.operations_gyd),
        adjustmentsGyd: num(row.adjustments_gyd),
        totalGyd: num(row.total_gyd),
        closedTotalGyd: num(row.closed_total_gyd),
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
  return {
    resetId: str(row.reset_id),
    contactId: str(row.contact_id),
    resetAt: str(row.reset_at),
    closed: {
      operationsGyd: num(closed.operations_gyd),
      adjustmentsGyd: num(closed.adjustments_gyd),
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
