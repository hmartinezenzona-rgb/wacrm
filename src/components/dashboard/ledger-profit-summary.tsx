"use client"

import { useState } from 'react'
import { TrendingUp } from 'lucide-react'
import type { LedgerProfitBucket, LedgerProfitData } from '@/lib/dashboard/types'
import { formatCurrencyShort } from '@/lib/currency'
import { EmptyState } from './empty-state'
import { Skeleton } from './skeleton'
import { cn } from '@/lib/utils'

interface LedgerProfitSummaryProps {
  data: LedgerProfitData | null
  loading: boolean
}

type Period = 'today' | 'thisWeek' | 'thisMonth'

import { useTranslations } from 'next-intl'

// Ledger amounts are always GYD (facturado_gyd/invertido_gyd/retorno_gyd) --
// the business's internal settlement currency, not the account's configurable
// default_currency used elsewhere on this dashboard. Hardcoding it here keeps
// this widget honest about what unit it's actually showing.
const LEDGER_CURRENCY = 'GYD'

export function LedgerProfitSummary({ data, loading }: LedgerProfitSummaryProps) {
  const t = useTranslations('Dashboard.ledgerProfit')
  const [period, setPeriod] = useState<Period>('today')

  const bucket: LedgerProfitBucket | null = data ? data[period] : null

  return (
    <section className="rounded-xl border border-border bg-card tarjeta-elevada">
      <header className="flex items-center justify-between border-b border-border px-5 py-4">
        <div>
          <h2 className="text-sm font-semibold text-foreground">{t('title')}</h2>
          <p className="mt-0.5 text-xs text-muted-foreground">{t('description')}</p>
        </div>
        <div className="flex items-center gap-1 rounded-lg bg-muted/60 p-1">
          {(['today', 'thisWeek', 'thisMonth'] as const).map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => setPeriod(p)}
              className={cn(
                'rounded-md px-2.5 py-1 text-xs font-medium transition-colors',
                period === p
                  ? 'bg-secondary text-secondary-foreground'
                  : 'text-muted-foreground hover:text-foreground',
              )}
            >
              {t(`period.${p}`)}
            </button>
          ))}
        </div>
      </header>

      <div className="p-5">
        {loading || !bucket ? (
          <Skeleton className="h-28 w-full" />
        ) : bucket.operationCount === 0 ? (
          <EmptyState
            icon={TrendingUp}
            title={t('noOperations')}
            hint={t('noOperationsHint')}
          />
        ) : (
          <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
            <Tile label={t('operationCount')} value={bucket.operationCount.toLocaleString()} />
            <Tile
              label={t('facturado')}
              value={formatCurrencyShort(bucket.facturadoGyd, LEDGER_CURRENCY)}
            />
            <Tile
              label={t('invertido')}
              value={formatCurrencyShort(bucket.invertidoGyd, LEDGER_CURRENCY)}
            />
            <Tile
              label={t('retorno')}
              value={formatCurrencyShort(bucket.retornoGyd, LEDGER_CURRENCY)}
              highlight
            />
          </div>
        )}
      </div>
    </section>
  )
}

function Tile({
  label,
  value,
  highlight,
}: {
  label: string
  value: string
  highlight?: boolean
}) {
  return (
    <div className="rounded-lg bg-muted/40 px-4 py-3">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p
        className={cn(
          'mt-1 text-lg font-semibold tabular-nums',
          highlight ? 'text-primary' : 'text-foreground',
        )}
      >
        {value}
      </p>
    </div>
  )
}
