// ============================================================
// Pure aggregation over calculator ledger entries
// (`remittance_calculator_entries`, via `LedgerEntry` from
// `@/lib/calculator/ledger-read-model`) answering "who are my top
// clients" and "which destination currencies move the most volume".
// No I/O — same convention as `ledgerTotals()`: only
// `status === "completed"` entries contribute, since a
// `verified_pending` row has no financial snapshot yet and a `void`
// row was reversed.
// ============================================================

import type { LedgerEntry } from '@/lib/calculator/ledger-read-model'
import type { DestinationBreakdownEntry, TopClientEntry } from './types'

/**
 * Groups completed entries by `customerName` (a `null` name — no
 * identity on record for a `completed_operation` entry — becomes its
 * own bucket rather than being dropped), sums `facturadoGyd` per
 * client, sorts descending by that sum, and caps the result at
 * `limit`.
 */
export function topClientsFrom(
  entries: LedgerEntry[],
  limit = 5,
): TopClientEntry[] {
  const byClient = new Map<string | null, TopClientEntry>()

  for (const entry of entries) {
    if (entry.status !== 'completed') continue
    const key = entry.customerName
    const existing = byClient.get(key) ?? {
      customerName: key,
      operationCount: 0,
      facturadoGyd: 0,
    }
    existing.operationCount += 1
    existing.facturadoGyd += entry.facturadoGyd ?? 0
    byClient.set(key, existing)
  }

  return Array.from(byClient.values())
    .sort((a, b) => b.facturadoGyd - a.facturadoGyd)
    .slice(0, limit)
}

/**
 * Groups completed entries by `amountCurrency` (the client's
 * requested destination currency, not the GYD settlement currency),
 * sums `facturadoGyd` per currency, and sorts descending by that
 * sum.
 */
export function destinationBreakdownFrom(
  entries: LedgerEntry[],
): DestinationBreakdownEntry[] {
  const byCurrency = new Map<string, DestinationBreakdownEntry>()

  for (const entry of entries) {
    if (entry.status !== 'completed') continue
    const key = entry.amountCurrency
    const existing = byCurrency.get(key) ?? {
      currency: key,
      operationCount: 0,
      facturadoGyd: 0,
    }
    existing.operationCount += 1
    existing.facturadoGyd += entry.facturadoGyd ?? 0
    byCurrency.set(key, existing)
  }

  return Array.from(byCurrency.values()).sort(
    (a, b) => b.facturadoGyd - a.facturadoGyd,
  )
}
