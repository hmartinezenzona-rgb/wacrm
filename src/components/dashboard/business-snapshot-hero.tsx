"use client"

import { DollarSign, Percent, Repeat, TrendingUp, Wallet } from 'lucide-react'
import { useTranslations } from 'next-intl'
import type { LedgerProfitData } from '@/lib/dashboard/types'
import { formatCurrencyShort } from '@/lib/currency'
import { computeMarginPct } from '@/lib/dashboard/service-profitability'
import { MetricCard } from './metric-card'
import { SkeletonCard } from './skeleton'

interface BusinessSnapshotHeroProps {
  data: LedgerProfitData | null
  loading: boolean
}

// Ledger amounts are always GYD (facturado_gyd/invertido_gyd/retorno_gyd) --
// same rule as LedgerProfitSummary, which this hero reads its numbers from
// (ledgerProfit.today, no new query).
const LEDGER_CURRENCY = 'GYD'

/**
 * The five "how is the business doing today" numbers, promoted to the
 * very top of the dashboard (ahead of the chat/CRM metric cards) so
 * the real money signal is what's visible with no scrolling. Reuses
 * `ledgerProfit.today` — the same bucket `LedgerProfitSummary` already
 * fetches — so this is pure presentation, no new fetch.
 */
export function BusinessSnapshotHero({ data, loading }: BusinessSnapshotHeroProps) {
  const t = useTranslations('Dashboard.businessSnapshot')
  const today = data?.today ?? null
  const margenPct = today ? computeMarginPct(today.facturadoGyd, today.retornoGyd) : null

  return (
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-5">
      {loading || !today ? (
        Array.from({ length: 5 }).map((_, i) => <SkeletonCard key={i} />)
      ) : (
        <>
          <MetricCard
            title={t('operationCount')}
            value={today.operationCount.toLocaleString()}
            icon={Repeat}
          />
          <MetricCard
            title={t('facturado')}
            value={formatCurrencyShort(today.facturadoGyd, LEDGER_CURRENCY)}
            icon={DollarSign}
          />
          <MetricCard
            title={t('retorno')}
            value={formatCurrencyShort(today.retornoGyd, LEDGER_CURRENCY)}
            icon={TrendingUp}
            tone={today.retornoGyd > 0 ? 'good' : today.retornoGyd < 0 ? 'bad' : 'neutral'}
          />
          <MetricCard
            title={t('invertido')}
            value={formatCurrencyShort(today.invertidoGyd, LEDGER_CURRENCY)}
            icon={Wallet}
          />
          {/* No tone: unlike retorno (an unambiguous profit/loss
              signal), there's no established baseline yet to call a
              given margin "good" or "bad" — stays neutral until one
              exists. */}
          <MetricCard
            title={t('margen')}
            value={margenPct === null ? '—' : `${margenPct.toFixed(1)}%`}
            icon={Percent}
          />
        </>
      )}
    </div>
  )
}
