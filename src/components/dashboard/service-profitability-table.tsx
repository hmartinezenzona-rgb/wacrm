"use client"

import { ListOrdered } from 'lucide-react'
import { useTranslations } from 'next-intl'
import type { LedgerProfitData } from '@/lib/dashboard/types'
import { formatCurrencyShort } from '@/lib/currency'
import { EmptyState } from './empty-state'
import { Skeleton } from './skeleton'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'

interface ServiceProfitabilityTableProps {
  data: LedgerProfitData | null
  loading: boolean
}

// Ledger amounts are always GYD — same rule as LedgerProfitSummary/
// BusinessSnapshotHero/BusinessInsights.
const LEDGER_CURRENCY = 'GYD'

/**
 * Per-service (CUP/ZELLE/CLASICA/TROPICAL — the calculator ledger's
 * own taxonomy, NOT `remittance_operations.service_type`) profitability
 * this month, sorted by profit descending. Reads
 * `data.serviceProfitability` — the SAME `ledgerProfit` fetch every
 * other ledger widget on this dashboard already uses, no new fetch.
 * A plain comparison table, no color: this is a "which service earns
 * the most" comparison, not a fixed-identity chart like the currency
 * breakdown above it.
 */
export function ServiceProfitabilityTable({ data, loading }: ServiceProfitabilityTableProps) {
  const t = useTranslations('Dashboard.serviceProfitability')
  const rows = data?.serviceProfitability ?? []

  return (
    <section className="rounded-xl border border-border bg-card tarjeta-elevada">
      <header className="border-b border-border px-5 py-4">
        <h2 className="text-sm font-semibold text-foreground">{t('title')}</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">{t('description')}</p>
      </header>

      <div className="p-5">
        {loading || !data ? (
          <Skeleton className="h-40 w-full" />
        ) : rows.length === 0 ? (
          <EmptyState icon={ListOrdered} title={t('noOperations')} />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t('service')}</TableHead>
                <TableHead className="text-right">{t('operationCount')}</TableHead>
                <TableHead className="text-right">{t('facturado')}</TableHead>
                <TableHead className="text-right">{t('retorno')}</TableHead>
                <TableHead className="text-right">{t('margen')}</TableHead>
                <TableHead className="text-right">{t('ticketMedio')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.service}>
                  <TableCell className="font-medium text-foreground">{row.service}</TableCell>
                  <TableCell className="text-right tabular-nums text-muted-foreground">
                    {row.operationCount.toLocaleString()}
                  </TableCell>
                  <TableCell className="text-right tabular-nums text-foreground">
                    {formatCurrencyShort(row.facturadoGyd, LEDGER_CURRENCY)}
                  </TableCell>
                  <TableCell className="text-right tabular-nums text-foreground">
                    {formatCurrencyShort(row.retornoGyd, LEDGER_CURRENCY)}
                  </TableCell>
                  <TableCell className="text-right tabular-nums text-muted-foreground">
                    {row.margenPct === null ? '—' : `${row.margenPct.toFixed(1)}%`}
                  </TableCell>
                  <TableCell className="text-right tabular-nums text-muted-foreground">
                    {formatCurrencyShort(row.ticketMedioGyd, LEDGER_CURRENCY)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>
    </section>
  )
}
