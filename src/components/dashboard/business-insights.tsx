"use client"

import { Globe2, Users } from 'lucide-react'
import { useTranslations } from 'next-intl'
import type { BusinessInsightsData } from '@/lib/dashboard/types'
import { formatCurrencyShort } from '@/lib/currency'
import { EmptyState } from './empty-state'
import { Skeleton } from './skeleton'

interface BusinessInsightsProps {
  data: BusinessInsightsData | null
  loading: boolean
}

// Ledger amounts (facturadoGyd) are always GYD — same rule as
// LedgerProfitSummary/BusinessSnapshotHero. `byDestinationCurrency` is
// about `amount_currency` (the client's requested currency), a
// different axis from this GYD figure.
const LEDGER_CURRENCY = 'GYD'

// Fixed categorical identity, same --chart-* tokens ServiceVolumeDonut
// already uses for service_type — a currency keeps the same color
// everywhere on the dashboard instead of each widget inventing its own.
// A currency outside this fixed set (there are only two today: CUP/USD,
// see calculator_service_for_operation) folds into the neutral default
// rather than generating a new hue.
const CURRENCY_COLORS: Record<string, string> = {
  USD: 'var(--chart-1)',
  CUP: 'var(--chart-2)',
}
const DEFAULT_CURRENCY_COLOR = 'var(--muted-foreground)'

/**
 * "Who are my top clients" and "which destination currencies move the
 * most volume" this month, both from `loadBusinessInsights` /
 * `remittance_calculator_entries`. A `customerName === null` entry (no
 * identity on record for that completed operation) renders the
 * `unknownClient` fallback label — this widget has no phone to fall
 * back to, since `loadBusinessInsights` reads the same columns
 * `loadLedgerProfit` does and doesn't join contacts.
 */
export function BusinessInsights({ data, loading }: BusinessInsightsProps) {
  const t = useTranslations('Dashboard.businessInsights')
  const hasTopClients = (data?.topClients.length ?? 0) > 0
  const hasBreakdown = (data?.byDestinationCurrency.length ?? 0) > 0

  return (
    <section className="rounded-xl border border-border bg-card tarjeta-elevada">
      <header className="border-b border-border px-5 py-4">
        <h2 className="text-sm font-semibold text-foreground">{t('title')}</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">{t('description')}</p>
      </header>

      <div className="grid grid-cols-1 gap-4 p-5 lg:grid-cols-2">
        <div>
          <h3 className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            {t('topClientsTitle')}
          </h3>
          {loading || !data ? (
            <Skeleton className="h-40 w-full" />
          ) : !hasTopClients ? (
            <EmptyState icon={Users} title={t('noClients')} />
          ) : (
            <ul className="space-y-2">
              {data.topClients.map((client, i) => (
                <li
                  key={`${client.customerName ?? 'unknown'}-${i}`}
                  className="flex items-center justify-between gap-3 rounded-lg bg-muted/40 px-3 py-2"
                >
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-foreground">
                      {client.customerName || t('unknownClient')}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {t('operationCount', { count: client.operationCount })}
                    </p>
                  </div>
                  <span className="shrink-0 text-sm font-semibold tabular-nums text-foreground">
                    {formatCurrencyShort(client.facturadoGyd, LEDGER_CURRENCY)}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div>
          <h3 className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            {t('destinationBreakdownTitle')}
          </h3>
          {loading || !data ? (
            <Skeleton className="h-40 w-full" />
          ) : !hasBreakdown ? (
            <EmptyState icon={Globe2} title={t('noBreakdown')} />
          ) : (
            <ul className="space-y-2">
              {data.byDestinationCurrency.map((row) => (
                <li
                  key={row.currency}
                  className="flex items-center justify-between gap-3 rounded-lg bg-muted/40 px-3 py-2"
                >
                  <div className="flex min-w-0 items-center gap-2">
                    <span
                      className="h-2.5 w-2.5 flex-shrink-0 rounded-full"
                      style={{ background: CURRENCY_COLORS[row.currency] ?? DEFAULT_CURRENCY_COLOR }}
                      aria-hidden
                    />
                    <div className="min-w-0">
                      <p className="text-sm font-medium text-foreground">{row.currency}</p>
                      <p className="text-xs text-muted-foreground">
                        {t('operationCount', { count: row.operationCount })}
                      </p>
                    </div>
                  </div>
                  <span className="shrink-0 text-sm font-semibold tabular-nums text-foreground">
                    {formatCurrencyShort(row.facturadoGyd, LEDGER_CURRENCY)}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </section>
  )
}
