"use client"

import { useCallback, useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/use-auth'
import { formatCurrency } from '@/lib/currency'
import { PageHeader, PageShell } from '@/components/layout/page-header'
import {
  MessageSquare,
  UserPlus,
  DollarSign,
  Send,
} from 'lucide-react'

import {
  loadActivity,
  loadBusinessInsights,
  loadConversationsSeries,
  loadLedgerProfit,
  loadMetrics,
  loadOperationsFunnel,
  loadResponseTime,
  loadServiceVolume,
} from '@/lib/dashboard/queries'
import type {
  ActivityItem,
  BusinessInsightsData,
  ConversationsSeriesPoint,
  LedgerProfitData,
  MetricsBundle,
  OperationsFunnelData,
  ResponseTimeSummary,
  ServiceVolumeData,
} from '@/lib/dashboard/types'

import { MetricCard } from '@/components/dashboard/metric-card'
import { SkeletonCard } from '@/components/dashboard/skeleton'
import { QuickActions } from '@/components/dashboard/quick-actions'
import { OperationsFunnel } from '@/components/dashboard/operations-funnel'
import { ConversationsChart } from '@/components/dashboard/conversations-chart'
import { ServiceVolumeDonut } from '@/components/dashboard/service-volume-donut'
import { LedgerProfitSummary } from '@/components/dashboard/ledger-profit-summary'
import { BusinessSnapshotHero } from '@/components/dashboard/business-snapshot-hero'
import { BusinessInsights } from '@/components/dashboard/business-insights'
import { ResponseTimeChart } from '@/components/dashboard/response-time-chart'
import { ActivityFeed } from '@/components/dashboard/activity-feed'

import { useTranslations } from 'next-intl'

type RangeDays = 7 | 30 | 90

// Single source of truth for the response-time target — passed to
// both the query (so compliance is computed against it) and the
// chart (so the header pill shows the same number). Previously the
// chart had its own hardcoded default, completely disconnected from
// what loadResponseTime actually computed.
const RESPONSE_TIME_TARGET_MINUTES = 5

export default function DashboardPage() {
  const t = useTranslations('Dashboard.page')
  const { defaultCurrency } = useAuth()
  const [metrics, setMetrics] = useState<MetricsBundle | null>(null)
  const [metricsLoading, setMetricsLoading] = useState(true)

  const [range, setRange] = useState<RangeDays>(30)
  // Keep a cache per range so switching tabs doesn't re-fetch what we
  // already have. Ranges the user hasn't opened yet stay null and
  // trigger a fetch on first view.
  const [series, setSeries] = useState<Record<RangeDays, ConversationsSeriesPoint[] | null>>({
    7: null,
    30: null,
    90: null,
  })
  const [seriesLoading, setSeriesLoading] = useState(true)

  const [serviceVolume, setServiceVolume] = useState<ServiceVolumeData | null>(null)
  const [serviceVolumeLoading, setServiceVolumeLoading] = useState(true)

  const [operationsFunnel, setOperationsFunnel] = useState<OperationsFunnelData | null>(null)
  const [operationsFunnelLoading, setOperationsFunnelLoading] = useState(true)

  const [ledgerProfit, setLedgerProfit] = useState<LedgerProfitData | null>(null)
  const [ledgerProfitLoading, setLedgerProfitLoading] = useState(true)

  const [businessInsights, setBusinessInsights] = useState<BusinessInsightsData | null>(null)
  const [businessInsightsLoading, setBusinessInsightsLoading] = useState(true)

  const [responseTime, setResponseTime] = useState<ResponseTimeSummary | null>(null)
  const [responseTimeLoading, setResponseTimeLoading] = useState(true)

  const [activity, setActivity] = useState<ActivityItem[] | null>(null)
  const [activityLoading, setActivityLoading] = useState(true)

  const loadAll = useCallback(() => {
    const db = createClient()

    // Kick everything off in parallel. Each block has its own
    // setState + finally so a slow query doesn't hold up faster
    // sections — each widget shows its own skeleton independently.
    void loadMetrics(db)
      .then((m) => setMetrics(m))
      .catch((err) => console.error('[dashboard] metrics failed:', err))
      .finally(() => setMetricsLoading(false))

    void loadConversationsSeries(db, 30)
      .then((s) => setSeries((prev) => ({ ...prev, 30: s })))
      .catch((err) => console.error('[dashboard] series failed:', err))
      .finally(() => setSeriesLoading(false))

    void loadServiceVolume(db)
      .then((v) => setServiceVolume(v))
      .catch((err) => console.error('[dashboard] service volume failed:', err))
      .finally(() => setServiceVolumeLoading(false))

    void loadOperationsFunnel(db)
      .then((f) => setOperationsFunnel(f))
      .catch((err) => console.error('[dashboard] operations funnel failed:', err))
      .finally(() => setOperationsFunnelLoading(false))

    void loadLedgerProfit(db)
      .then((p) => setLedgerProfit(p))
      .catch((err) => console.error('[dashboard] ledger profit failed:', err))
      .finally(() => setLedgerProfitLoading(false))

    void loadBusinessInsights(db)
      .then((b) => setBusinessInsights(b))
      .catch((err) => console.error('[dashboard] business insights failed:', err))
      .finally(() => setBusinessInsightsLoading(false))

    void loadResponseTime(db, RESPONSE_TIME_TARGET_MINUTES)
      .then((r) => setResponseTime(r))
      .catch((err) => console.error('[dashboard] response time failed:', err))
      .finally(() => setResponseTimeLoading(false))

    // Fetch up to 50 so the biggest page-size option in the feed
    // (50 rows) is already in memory — switching sizes then becomes
    // a pure client-side slice with no extra round trip.
    void loadActivity(db, 50)
      .then((a) => setActivity(a))
      .catch((err) => console.error('[dashboard] activity failed:', err))
      .finally(() => setActivityLoading(false))
  }, [])

  useEffect(() => {
    loadAll()
  }, [loadAll])

  // Range switch handler — kept in an event callback (not an effect)
  // so the setState calls stay out of the react-hooks/set-state-in-effect
  // rule's way. The cached bucket check means switching back to a
  // previously-viewed range is instant and doesn't re-fetch.
  const handleRangeChange = useCallback(
    (r: RangeDays) => {
      setRange(r)
      if (series[r] !== null) return
      setSeriesLoading(true)
      const db = createClient()
      loadConversationsSeries(db, r)
        .then((s) => setSeries((prev) => ({ ...prev, [r]: s })))
        .catch((err) => console.error('[dashboard] series failed:', err))
        .finally(() => setSeriesLoading(false))
    },
    [series],
  )

  return (
    <PageShell className="space-y-5">
      <PageHeader title={t('title')} description={t('description')} />

      {/* Business snapshot: the real "how is the business doing today"
          numbers (remesas/monto movido/ganancia/invertido hoy), promoted
          above everything else so this is what's visible with no
          scrolling — the chat/CRM metric cards below are useful but
          aren't the business's money numbers. Reuses ledgerProfit.today,
          no new fetch. */}
      <BusinessSnapshotHero data={ledgerProfit} loading={ledgerProfitLoading} />

      {/* Quick actions */}
      <QuickActions />

      {/* Live shape of the one real sequential process this business
          runs (remittance_operations.status) — same widget type
          HubSpot/Salesforce/Zoho/Pipedrive use for sales-stage
          distribution, applied to this CRM's actual pipeline. Sits
          right after quick actions: it's the closest thing this
          dashboard has to "how's the core process doing right now". */}
      <OperationsFunnel data={operationsFunnel} loading={operationsFunnelLoading} />

      {/* Real margin from the calculator ledger (remittance_calculator_entries):
          facturado - invertido = retorno, over completed entries only. This
          is actual profit, not volume — a different signal from the service
          volume donut below, which shows how much moved, not what it earned. */}
      <LedgerProfitSummary data={ledgerProfit} loading={ledgerProfitLoading} />

      {/* Who's billing the most and which destination currencies move the
          most volume this month — same read path as LedgerProfitSummary
          (remittance_calculator_entries, completed-only), aggregated by
          client and by amount_currency instead of by time bucket. */}
      <BusinessInsights data={businessInsights} loading={businessInsightsLoading} />

      {/* Secondary metric cards: chat/CRM activity signals (active
          conversations, new contacts, operations in progress, messages
          sent). Still useful, just no longer the first thing seen — the
          business snapshot hero above answers "how's the business doing"
          before this answers "how's the inbox doing". */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {metricsLoading || !metrics ? (
          Array.from({ length: 4 }).map((_, i) => <SkeletonCard key={i} />)
        ) : (
          <>
            <MetricCard
              title={t('activeConversations')}
              value={metrics.activeConversations.current.toLocaleString()}
              icon={MessageSquare}
              delta={{
                sign: metrics.activeConversations.previous,
                label: deltaLabel(
                  metrics.activeConversations.previous,
                  t('newTodayVsYesterday'),
                  t('noChange', { suffix: t('newTodayVsYesterday') })
                ),
              }}
            />
            <MetricCard
              title={t('newContactsToday')}
              value={metrics.newContactsToday.current.toLocaleString()}
              icon={UserPlus}
              delta={{
                sign:
                  metrics.newContactsToday.current - metrics.newContactsToday.previous,
                label: deltaLabel(
                  metrics.newContactsToday.current - metrics.newContactsToday.previous,
                  t('vsYesterday'),
                  t('noChange', { suffix: t('vsYesterday') })
                ),
              }}
            />
            <MetricCard
              title={t('operationsInProgress')}
              value={formatCurrency(metrics.operationsInProgressValue, defaultCurrency)}
              icon={DollarSign}
              subtitle={t('operationsInProgressCount', { count: metrics.operationsInProgressCount })}
            />
            <MetricCard
              title={t('messagesSentToday')}
              value={metrics.messagesSentToday.current.toLocaleString()}
              icon={Send}
              delta={{
                sign:
                  metrics.messagesSentToday.current - metrics.messagesSentToday.previous,
                label: deltaLabel(
                  metrics.messagesSentToday.current - metrics.messagesSentToday.previous,
                  t('vsYesterday'),
                  t('noChange', { suffix: t('vsYesterday') })
                ),
              }}
            />
          </>
        )}
      </div>

      {/* Charts row. Was a 3/2 split with the pipeline donut, pulled
          when the pipelines management UI it depended on was removed
          (fix commit 4100a65). Replacement: today's remittance volume
          by service_type, reading through remittance_operations
          instead of the retired deals/pipeline model. */}
      {/* items-stretch (the grid default) stretches the two columns to
          match the tallest sibling; adding h-full on each wrapper and
          on the inner panels makes both cards actually fill that
          stretched height so their rounded borders line up. */}
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-5">
        <div className="h-full lg:col-span-3">
          <ConversationsChart
            series={series}
            loading={seriesLoading}
            range={range}
            onRangeChange={handleRangeChange}
          />
        </div>
        <div className="h-full lg:col-span-2">
          <ServiceVolumeDonut
            data={serviceVolume}
            loading={serviceVolumeLoading}
            currency={defaultCurrency}
          />
        </div>
      </div>

      {/* Response time */}
      <ResponseTimeChart
        data={responseTime}
        loading={responseTimeLoading}
        thresholdMinutes={RESPONSE_TIME_TARGET_MINUTES}
      />

      {/* Activity feed */}
      <ActivityFeed items={activity} loading={activityLoading} />
    </PageShell>
  )
}

// ------------------------------------------------------------

function deltaLabel(delta: number, suffix: string, noChangeLabel: string): string {
  if (delta === 0) return noChangeLabel
  const sign = delta > 0 ? '+' : ''
  return `${sign}${delta.toLocaleString()} ${suffix}`
}
