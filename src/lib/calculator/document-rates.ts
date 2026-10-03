/**
 * Maps the calculator document's four GLOBAL rates (as stored on
 * `remittance_calculator_documents`) onto the pure formula engine's
 * per-entry rate inputs, for the three delivery methods a completed
 * `remittance_operations` row can be resolved to without guessing:
 * CUP, ZELLE, CLASICA, TROPICAL (see `projection.ts`'s `serviceFor`).
 * USDT has no structured signal anywhere in the schema yet (no
 * `delivery_method`/`beneficiary_type` value identifies it), so it is
 * included here only as a formula the day that signal exists — nothing
 * calls it with a real operation today.
 *
 * The owner-confirmed rule: every one of these services' amount is ALWAYS
 * derived from the client's GYD deposit (`quoted_source_amount`), never
 * from `quoted_destination_amount` — that field can be a poorly-derived
 * AI/vision estimate and is not a trustworthy calculation basis. See
 * `deriveAmountFromDeposit` for the exact per-service derivation. ZELLE,
 * CLASICA and TROPICAL always round DOWN to the whole unit (floor), never
 * up. Rounding is done in the business's favour: a 75,000 GYD deposit at
 * 260 GYD/USD is 288.46 USD, and delivering 289 would hand over
 * 289 x 260 = 75,140 GYD of value against a 75,000 GYD deposit — 140 GYD
 * out of the business's pocket on every remittance. This mirrors the n8n
 * bot, which has always floored for the same reason.
 *
 * This module does NOT write to the database; the DB-side trigger that
 * performs the actual atomic snapshot write at delivery is a later slice's
 * concern. Every function here is pure and is meant to mirror that SQL 1:1
 * — keep both in sync if either changes. It is also used by the calculator
 * read side to explain, without recomputing anything, why a persisted
 * `verified_pending`/`pending_rates` row still has no financial snapshot
 * (`missingDocumentRates`).
 *
 * Deviation from the ported source (design decision 9/10, spec "Global Rate
 * Snapshot at Delivery"): the source's `CalculatorDocumentRates.cupGlobalRate`
 * was NOT NULL (DB-defaulted to 3), and `computeAutoCompletionSnapshot`/
 * `deriveAmountFromDeposit` silently returned `null` when a required rate
 * was missing. Per decision 9 the DB rate now carries NO default (NULL CHECK
 * > 0), so `cupGlobalRate` is `number | null` here too, and a missing
 * required rate at the point financials are actually computed now throws
 * `CalculatorValidationError` naming the field — it is never computed with
 * zero or a guessed default. `deriveAmountFromDeposit` keeps returning
 * `null` only for an invalid/non-positive deposit amount (not a rate
 * problem), but also throws when the conversion rate itself is missing.
 */
import { CalculatorValidationError } from "./errors";
import { calculateEntry } from "./formulas";
import type {
  CalculatorEntryFinancials,
  CalculatorEntryRates,
  CalculatorServiceType,
} from "./types";

/** The four rates an administrator configures once per account, mirroring
 * `calculator_rate_versions` columns cup_global_rate/usdt_buy_gyd/
 * usdt_sell_gyd/usdt_sell_cup. None of the four carries a default anymore
 * (design decision 9): every field is `number | null`, and `null` means
 * "not set yet" — never treated as 0 or a commercial default. */
export interface CalculatorDocumentRates {
  cupGlobalRate: number | null;
  usdtBuyGyd: number | null;
  usdtSellGyd: number | null;
  usdtSellCup: number | null;
  /** Cash-dollar (EFECTIVO) sale rate, `efectivo_usd_gyd`. Optional so callers
   * that never price cash need not carry it; absent means "not set". */
  efectivoUsdGyd?: number | null;
}

/** Delivery methods a completed structured operation can resolve to. Kept
 * separate from `CalculatorServiceType` (which also includes MLC/RECARGA/
 * SALDO_MOVIL/DIRECTO — services only reachable from the manual textarea,
 * never from a structured operation). */
export type CalculatorAutoCompletionService =
  | "CUP"
  | "ZELLE"
  | "CLASICA"
  | "TROPICAL"
  | "USDT"
  | "EFECTIVO";

const REQUIRED_DOCUMENT_RATE_FIELDS: Record<
  CalculatorAutoCompletionService,
  ReadonlyArray<keyof CalculatorDocumentRates>
> = {
  CUP: ["cupGlobalRate", "usdtSellCup", "usdtBuyGyd"],
  ZELLE: ["usdtBuyGyd", "usdtSellGyd"],
  CLASICA: ["usdtBuyGyd", "usdtSellGyd"],
  TROPICAL: ["usdtBuyGyd", "usdtSellGyd"],
  USDT: ["usdtBuyGyd", "usdtSellGyd"],
  // Migration 193: a cash dollar costs the shared buy rate but sells at its own rate.
  EFECTIVO: ["usdtBuyGyd", "efectivoUsdGyd"],
};

/** Which of the service's required document rates are currently unset.
 * Empty array means the service is ready for an automatic snapshot. Never
 * substitutes a default — a field is either present (non-null) or missing.
 * Used by the read side to explain a `pending_rates` entry's
 * `missing_inputs`, and internally by `computeAutoCompletionSnapshot`
 * before it throws. */
export function missingDocumentRates(
  service: CalculatorAutoCompletionService,
  doc: CalculatorDocumentRates,
): Array<keyof CalculatorDocumentRates> {
  return REQUIRED_DOCUMENT_RATE_FIELDS[service].filter((field) => doc[field] == null);
}

/** Maps the document's global rates onto the formula engine's per-entry
 * rate shape for one service. Does not validate completeness — call
 * `missingDocumentRates` first, or rely on `computeAutoCompletionSnapshot`
 * which does both. */
export function rateInputForService(
  service: CalculatorAutoCompletionService,
  doc: CalculatorDocumentRates,
): CalculatorEntryRates {
  if (service === "CUP") {
    return {
      costGyd: doc.usdtBuyGyd ?? undefined,
      cupRate: doc.usdtSellCup ?? undefined,
      cupGlobalRate: doc.cupGlobalRate ?? undefined,
    };
  }
  if (service === "EFECTIVO") {
    return {
      costGyd: doc.usdtBuyGyd ?? undefined,
      saleGyd: doc.efectivoUsdGyd ?? undefined,
    };
  }
  return {
    costGyd: doc.usdtBuyGyd ?? undefined,
    saleGyd: doc.usdtSellGyd ?? undefined,
  };
}

/**
 * Computes the immutable facturado/invertido/retorno snapshot for a
 * completed operation from an already-derived service amount. This remains
 * the raw formula entry point used by manual and unit-level calculator code;
 * use computeAutoCompletionSnapshotFromDeposit for structured remittances.
 *
 * Throws CalculatorValidationError naming the first missing rate instead of
 * returning null — see the module docstring's deviation note.
 */
export function computeAutoCompletionSnapshot(
  service: CalculatorAutoCompletionService,
  amount: number,
  doc: CalculatorDocumentRates,
): CalculatorEntryFinancials {
  const missing = missingDocumentRates(service, doc);
  if (missing.length > 0) {
    throw new CalculatorValidationError(
      `Missing required document rate(s) for ${service}: ${missing.join(", ")}`,
      missing[0],
    );
  }
  const financialService: CalculatorServiceType = service;
  return calculateEntry({
    service: financialService,
    amount,
    ...rateInputForService(service, doc),
  });
}

/**
 * Derives the number of service units from the customer's GYD deposit.
 * ZELLE/CLASICA/TROPICAL are sold in whole units at the global GYD sale rate;
 * the quotient is always rounded DOWN to the whole unit (floor), in the
 * business's favour — never up, which would deliver more value than was
 * deposited. CUP is first converted with the global GYD->CUP rate.
 *
 * An invalid/non-positive deposit amount returns `null` (not a rate
 * problem). A missing conversion rate throws CalculatorValidationError —
 * it never becomes a zero or a guessed value.
 */
export function deriveAmountFromDeposit(
  service: CalculatorAutoCompletionService,
  sourceAmountGyd: number,
  doc: CalculatorDocumentRates,
): number | null {
  if (!Number.isFinite(sourceAmountGyd) || sourceAmountGyd <= 0) return null;
  if (service === "CUP") {
    if (doc.cupGlobalRate == null) {
      throw new CalculatorValidationError(
        "Missing required document rate: cupGlobalRate",
        "cupGlobalRate",
      );
    }
    const amount = sourceAmountGyd * doc.cupGlobalRate;
    return Number.isFinite(amount) && amount > 0 ? amount : null;
  }
  if (
    service === "ZELLE" ||
    service === "CLASICA" ||
    service === "TROPICAL" ||
    service === "EFECTIVO"
  ) {
    // EFECTIVO sells at its own cash rate; the others at the USDT sale rate.
    const field = service === "EFECTIVO" ? "efectivoUsdGyd" : "usdtSellGyd";
    const saleRate = doc[field];
    if (saleRate == null) {
      throw new CalculatorValidationError(
        `Missing required document rate: ${field}`,
        field,
      );
    }
    const amount = Math.floor(sourceAmountGyd / saleRate);
    return Number.isFinite(amount) && amount > 0 ? amount : null;
  }
  return null;
}

/** Calculates the immutable snapshot using the customer's deposit as basis.
 * Returns `null` only when the deposit amount itself is invalid;
 * `deriveAmountFromDeposit`/`computeAutoCompletionSnapshot` throw
 * CalculatorValidationError for a missing rate. */
export function computeAutoCompletionSnapshotFromDeposit(
  service: CalculatorAutoCompletionService,
  sourceAmountGyd: number,
  doc: CalculatorDocumentRates,
): { amount: number; financials: CalculatorEntryFinancials } | null {
  const amount = deriveAmountFromDeposit(service, sourceAmountGyd, doc);
  if (amount == null) return null;
  const financials = computeAutoCompletionSnapshot(service, amount, doc);
  return { amount, financials };
}
