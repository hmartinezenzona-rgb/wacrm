/**
 * Totals only ever include `status: "completed"` entries. A
 * `verified_pending` completed-operation entry can be displayed, but it
 * contributes zero to Facturado/Invertido/Retorno until the operation
 * actually completes.
 *
 * `filterIncludedEntries` is a plain status filter and, on its own, does
 * not dedupe — a caller that hands it raw entries containing duplicate
 * `completed_operation` rows for the same operationId gets both summed.
 * `calculateTotals` is the safe entry point: it runs
 * `dedupeCompletedOperationEntries` first, so a caller can pass entries in
 * any order (or with duplicates from a live sync + backfill) and never have
 * an operationId counted twice, regardless of whether the surviving entry
 * ends up completed or pending.
 */
import { dedupeCompletedOperationEntries } from "./dedupe";
import type { CalculatorEntry, CalculatorTotals } from "./types";

export function filterIncludedEntries(
  entries: CalculatorEntry[],
): CalculatorEntry[] {
  return entries.filter((entry) => entry.status === "completed");
}

export function calculateTotals(entries: CalculatorEntry[]): CalculatorTotals {
  const deduped = dedupeCompletedOperationEntries(entries);
  const included = filterIncludedEntries(deduped);
  return included.reduce<CalculatorTotals>(
    (totals, entry) => ({
      facturadoGyd: totals.facturadoGyd + entry.facturadoGyd,
      invertidoGyd: totals.invertidoGyd + entry.invertidoGyd,
      retornoGyd: totals.retornoGyd + entry.retornoGyd,
      count: totals.count + 1,
    }),
    { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 },
  );
}
