import { normalizeCompletedOperationEntry } from "./entries";
import { deriveAmountFromDeposit, type CalculatorAutoCompletionService } from "./document-rates";
import type {
  CalculatorEntry,
  CalculatorEntryRates,
  CalculatorServiceType,
  CalculatorEntryStatus,
} from "./types";

export interface StructuredRemittanceCalculatorSource {
  operationId: string;
  status: string;
  depositVerified: boolean;
  deliveryMethod: string | null;
  destinationAmount: number | null;
  destinationCurrency: string | null;
  /** The client's GYD deposit (`remittance_operations.quoted_source_amount`)
   * and its currency (`source_currency`). Carried through so a completed
   * candidate can be finalized from the deposit rather than from
   * `destinationAmount` — see `materializeProjectedOperation`. Never used to
   * guess anything when the currency isn't GYD. */
  sourceAmount?: number | null;
  sourceCurrency?: string | null;
  customerName?: string | null;
  completedAt?: string | null;
  createdAt?: string | null;
  day?: string | null;
  period?: string | null;
}

export type CalculatorProjectionRejection =
  | "missing_operation_id"
  | "deposit_not_verified"
  | "operation_not_eligible"
  | "unknown_delivery_method"
  | "incompatible_currency"
  | "missing_amount"
  | "missing_currency"
  | "missing_date";

export interface CalculatorProjectionCandidate {
  id: string;
  operationId: string;
  customerName: string | null;
  status: CalculatorEntryStatus;
  service: CalculatorServiceType;
  amount: number;
  amountCurrency: string;
  date: string;
  day?: string;
  period?: string;
  financialBlockers: string[];
  /** Carried through from the source for `materializeProjectedOperation`;
   * see `StructuredRemittanceCalculatorSource.sourceAmount`. */
  sourceAmount?: number | null;
  sourceCurrency?: string | null;
}

export type CalculatorProjection =
  | { kind: "candidate"; candidate: CalculatorProjectionCandidate }
  | { kind: "rejected"; reason: CalculatorProjectionRejection };

function canonicalMethod(method: string | null): string | null {
  const normalized = method?.trim().toLowerCase().replace(/[_-]+/g, " ");
  return normalized || null;
}

type ServiceRejection = "unknown_delivery_method" | "incompatible_currency";

function serviceFor(source: StructuredRemittanceCalculatorSource):
  | CalculatorServiceType
  | ServiceRejection {
  const method = canonicalMethod(source.deliveryMethod);
  if (method === "cuban card") {
    return source.destinationCurrency?.trim().toUpperCase() === "CUP"
      ? "CUP"
      : "incompatible_currency";
  }
  if (method === "zelle") return "ZELLE";
  if (method === "usdt") return "USDT";
  if (method === "classic" || method === "clasica" || method === "clásica") {
    return "CLASICA";
  }
  if (method === "tropical") return "TROPICAL";
  return "unknown_delivery_method";
}

function financialBlockers(service: CalculatorServiceType): string[] {
  if (service === "CUP") return ["costGyd", "cupRate", "cupGlobalRate"];
  return ["costGyd", "saleGyd"];
}

function stableDate(source: StructuredRemittanceCalculatorSource): string | null {
  return source.completedAt?.trim() || source.createdAt?.trim() || null;
}

export function projectStructuredOperation(
  source: StructuredRemittanceCalculatorSource,
): CalculatorProjection {
  const operationId = source.operationId?.trim();
  if (!operationId) return { kind: "rejected", reason: "missing_operation_id" };
  if (!source.depositVerified) {
    return { kind: "rejected", reason: "deposit_not_verified" };
  }
  if (source.status === "cancelled" || source.status === "incident") {
    return { kind: "rejected", reason: "operation_not_eligible" };
  }

  if (source.destinationAmount == null) {
    return { kind: "rejected", reason: "missing_amount" };
  }
  if (!Number.isFinite(source.destinationAmount) || source.destinationAmount <= 0) {
    return { kind: "rejected", reason: "missing_amount" };
  }
  const amountCurrency = source.destinationCurrency?.trim().toUpperCase();
  if (!amountCurrency) return { kind: "rejected", reason: "missing_currency" };
  const service = serviceFor(source);
  if (service === "unknown_delivery_method" || service === "incompatible_currency") {
    return { kind: "rejected", reason: service };
  }
  const date = stableDate(source);
  if (!date) return { kind: "rejected", reason: "missing_date" };

  return {
    kind: "candidate",
    candidate: {
      id: `operation:${operationId}`,
      operationId,
      customerName: source.customerName?.trim() || null,
      status: source.status === "completed" ? "completed" : "verified_pending",
      service,
      amount: source.destinationAmount,
      amountCurrency,
      date,
      ...(source.day?.trim() ? { day: source.day.trim() } : {}),
      ...(source.period?.trim() ? { period: source.period.trim() } : {}),
      financialBlockers: financialBlockers(service),
      sourceAmount: source.sourceAmount ?? null,
      sourceCurrency: source.sourceCurrency ?? null,
    },
  };
}

const DEPOSIT_DERIVED_SERVICES = new Set<CalculatorServiceType>([
  "CUP",
  "ZELLE",
  "CLASICA",
  "TROPICAL",
]);

/**
 * The owner-confirmed rule (see document-rates.ts) is to always derive these
 * services' amount from the client's GYD deposit rather than from
 * `destinationAmount`, which can be a poorly-derived estimate. This only
 * applies once the deposit is known AND its currency is GYD — never
 * inferred otherwise, so `candidate.amount` (the raw destinationAmount) is
 * kept as-is when the deposit is absent or non-GYD.
 *
 * Deviation from the ported source: the source converted a missing
 * `rates.cupGlobalRate` to `NaN` so `deriveAmountFromDeposit` would return
 * `null` and this would fall back to `candidate.amount` silently. Per
 * design decision 9/10, `CalculatorDocumentRates.cupGlobalRate` is now
 * `number | null` with no default, and `deriveAmountFromDeposit` throws
 * `CalculatorValidationError` naming the missing rate instead of returning
 * null for it — so a GYD-deposit CUP candidate materialized without
 * `cupGlobalRate` now throws instead of silently using the raw destination
 * amount. Callers must supply the rate (already listed in
 * `candidate.financialBlockers`) before materializing.
 */
function depositDerivedAmount(
  candidate: CalculatorProjectionCandidate,
  rates: CalculatorEntryRates,
): number | null {
  if (!DEPOSIT_DERIVED_SERVICES.has(candidate.service)) return null;
  const sourceAmount = candidate.sourceAmount;
  if (sourceAmount == null) return null;
  if (candidate.sourceCurrency?.trim().toUpperCase() !== "GYD") return null;
  return deriveAmountFromDeposit(
    candidate.service as CalculatorAutoCompletionService,
    sourceAmount,
    {
      cupGlobalRate: rates.cupGlobalRate ?? null,
      usdtBuyGyd: rates.costGyd ?? null,
      usdtSellGyd: rates.saleGyd ?? null,
      usdtSellCup: rates.cupRate ?? null,
    },
  );
}

export function materializeProjectedOperation(
  candidate: CalculatorProjectionCandidate,
  rates: CalculatorEntryRates,
): CalculatorEntry {
  return normalizeCompletedOperationEntry({
    id: candidate.id,
    operationId: candidate.operationId,
    status: candidate.status,
    service: candidate.service,
    amount: depositDerivedAmount(candidate, rates) ?? candidate.amount,
    amountCurrency: candidate.amountCurrency,
    ...(candidate.customerName ? { customerName: candidate.customerName } : {}),
    date: candidate.date,
    ...(candidate.day ? { day: candidate.day } : {}),
    ...(candidate.period ? { period: candidate.period } : {}),
    ...rates,
  });
}
