// ============================================================
// Pure aggregation over calculator ledger entries
// (`remittance_calculator_entries`, via `LedgerEntry` from
// `@/lib/calculator/ledger-read-model`), grouping by the ledger's own
// `service` taxonomy (CUP/ZELLE/CLASICA/TROPICAL — computed by
// `calculator_service_for_operation()` in migration 104, NOT
// `remittance_operations.service_type`, an unrelated taxonomy) to
// answer "which service is actually profitable". No I/O — same
// convention as `ledgerTotals()`/`business-insights.ts`: only
// `status === "completed"` entries contribute, since a
// `verified_pending` row has no financial snapshot yet and a `void`
// row was reversed.
// ============================================================

import type { LedgerEntry } from '@/lib/calculator/ledger-read-model'
import type { ServiceProfitabilityRow } from './types'

/**
 * `margenPct = retornoGyd / facturadoGyd * 100`, rounded to nothing
 * (callers format for display) — `null` when `facturadoGyd` is 0, so
 * a zero-billed bucket renders as "—" instead of `NaN`/`Infinity`.
 */
export function computeMarginPct(
  facturadoGyd: number,
  retornoGyd: number,
): number | null {
  if (facturadoGyd === 0) return null
  return (retornoGyd / facturadoGyd) * 100
}

/**
 * Groups completed entries by `service` (the ledger's CUP/ZELLE/
 * CLASICA/TROPICAL taxonomy), summing `facturadoGyd`/`retornoGyd` per
 * service and deriving `margenPct` (null on zero facturado) and
 * `ticketMedioGyd` (`facturadoGyd / operationCount`). Sorted by
 * `retornoGyd` descending — the most profitable service first.
 */
export function serviceProfitabilityFrom(
  entries: LedgerEntry[],
): ServiceProfitabilityRow[] {
  const byService = new Map<
    string,
    { operationCount: number; facturadoGyd: number; retornoGyd: number }
  >()

  for (const entry of entries) {
    if (entry.status !== 'completed') continue
    const key = entry.service
    const existing = byService.get(key) ?? {
      operationCount: 0,
      facturadoGyd: 0,
      retornoGyd: 0,
    }
    existing.operationCount += 1
    existing.facturadoGyd += entry.facturadoGyd ?? 0
    existing.retornoGyd += entry.retornoGyd ?? 0
    byService.set(key, existing)
  }

  return Array.from(byService.entries())
    .map(([service, totals]) => ({
      service,
      operationCount: totals.operationCount,
      facturadoGyd: totals.facturadoGyd,
      retornoGyd: totals.retornoGyd,
      margenPct: computeMarginPct(totals.facturadoGyd, totals.retornoGyd),
      ticketMedioGyd: totals.facturadoGyd / totals.operationCount,
    }))
    .sort((a, b) => b.retornoGyd - a.retornoGyd)
}
