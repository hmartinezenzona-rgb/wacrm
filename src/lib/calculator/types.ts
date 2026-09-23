/**
 * Calculator domain types — normalized shape for the weekly closing
 * calculator described in `CALCULADORA OSMANY.txt` (the owner's reference
 * HTML). This module carries no UI, Supabase, or writer concerns; it is
 * pure data + pure functions so a future slice can feed it either manual
 * entries or completed remittance operations.
 */

/** Service identifiers, mirrored from the reference calculator's `tipo`
 * classification. `SALDO_MOVIL` replaces the reference's "SALDO MOVIL"
 * (space) so it can be used as a plain identifier; the formula is
 * unchanged. */
export type CalculatorServiceType =
  | "CUP"
  | "ZELLE"
  | "MLC"
  | "CLASICA"
  | "TROPICAL"
  | "USDT"
  | "RECARGA"
  | "SALDO_MOVIL"
  | "DIRECTO";

export type CalculatorEntrySource = "manual" | "completed_operation";

/** Only `completed` counts toward totals. `verified_pending` entries may be
 * shown but must never be summed — see `filterIncludedEntries`. */
export type CalculatorEntryStatus = "completed" | "verified_pending";

/**
 * Rate inputs a single entry's formula draws from. Field names follow the
 * public contract (costGyd/saleGyd/cupRate/cupGlobalRate) even though a
 * couple of services reuse them for a role beyond their literal name:
 *
 * - `costGyd` is always the rate multiplied into the invested side.
 * - `saleGyd` is always the rate the billed side is derived from, for
 *   every service except CUP (see `cupGlobalRate`).
 * - `cupRate` is the auxiliary conversion rate CUP (`tasaCupUsdt`) and
 *   RECARGA/SALDO_MOVIL (`tasa USDT GYD`) need on top of cost/sale — both
 *   are "how many units of X per USDT" in the reference calculator.
 * - `cupGlobalRate` is CUP's own billed-side rate (`tarifaCupGlobal` in the
 *   reference HTML): a single GYD/CUP rate the reference calculator keeps
 *   as one global input shared by every CUP row, entirely separate from
 *   the per-entry detail `saleGyd` represents for other services. CUP
 *   must not reuse `saleGyd` for this — the two rates come from different
 *   inputs in the reference calculator and conflating them silently
 *   produces the wrong facturado.
 *
 * DIRECTO ignores all four (facturado = amount, invertido = 0).
 */
export interface CalculatorEntryRates {
  costGyd?: number;
  saleGyd?: number;
  cupRate?: number;
  cupGlobalRate?: number;
}

/** Fields needed to run the formula for one entry, independent of its
 * identity/bookkeeping metadata. */
export interface CalculatorEntryFinancialInput extends CalculatorEntryRates {
  service: CalculatorServiceType;
  amount: number;
  /** Percentage (e.g. 30 for 30%), applied only by ZELLE/MLC/CLASICA/TROPICAL. */
  discountPct?: number;
}

export interface CalculatorEntryFinancials {
  facturadoGyd: number;
  invertidoGyd: number;
  retornoGyd: number;
}

/** Identity/bookkeeping fields shared by manual and completed-operation
 * entries, before source/status are attached. */
export interface CalculatorEntryDraft extends CalculatorEntryFinancialInput {
  id: string;
  customerName?: string | null;
  date: string;
  day?: string;
  period?: string;
  amountCurrency: string;
}

export type ManualCalculatorEntryDraft = CalculatorEntryDraft;

export interface CompletedOperationCalculatorEntryDraft
  extends CalculatorEntryDraft {
  operationId: string;
  status: CalculatorEntryStatus;
}

/** Fully normalized, calculated entry — the module's public output shape. */
export interface CalculatorEntry
  extends CalculatorEntryDraft,
    CalculatorEntryFinancials {
  source: CalculatorEntrySource;
  status: CalculatorEntryStatus;
  operationId?: string;
}

export interface CalculatorTotals extends CalculatorEntryFinancials {
  count: number;
}
