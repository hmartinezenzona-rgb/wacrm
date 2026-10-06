"use client"

import { Clock } from 'lucide-react'
import { DOW_SHORT_MON_FIRST } from '@/lib/dashboard/date-utils'
import type { ResponseTimeSummary } from '@/lib/dashboard/types'
import { BarChart } from '@/components/tremor/bar-chart'
import { EmptyState } from './empty-state'
import { Skeleton } from './skeleton'

interface ResponseTimeChartProps {
  data: ResponseTimeSummary | null
  loading: boolean
  /** Minutes. Passed straight through to `loadResponseTime` on the
   *  caller's side too, so the header's compliance percentage is
   *  computed against the same threshold this prop displays — keep
   *  the two in sync at the call site. Surfaced as a pill in the
   *  header; the hand-rolled SVG version drew it as a horizontal
   *  dashed line on the chart, which Tremor BarChart doesn't expose
   *  a primitive for. A follow-up can introduce an overlay or extend
   *  the vendored BarChart with a `referenceLines` prop. */
  thresholdMinutes?: number
}

import { useTranslations } from 'next-intl'

// Single category, single colour — the data is "average minutes
// per weekday". Tremor expects categories as the second tuple in
// the row object, so we shape the buckets into
// `{ day: 'Mon', 'Avg minutes': 4.2 }` rows below.
export function ResponseTimeChart({
  data,
  loading,
  thresholdMinutes = 5,
}: ResponseTimeChartProps) {
  const t = useTranslations('Dashboard.responseTimeChart')
  const CATEGORY = t('seriesAvgMinutes')
  const hasData = data?.buckets.some((b) => b.avgMinutes != null) ?? false

  // Map buckets → Tremor rows. Null `avgMinutes` (no samples)
  // collapses to 0; the chart will render an empty slot for it.
  // We attach `samples` on the row so a future customTooltip can
  // surface "no samples" copy without losing the data shape.
  const chartData =
    data?.buckets.map((b, i) => ({
      day: DOW_SHORT_MON_FIRST[i],
      [CATEGORY]: b.avgMinutes ?? 0,
      samples: b.samples,
    })) ?? []

  return (
    <section className="rounded-xl border border-border bg-card tarjeta-elevada">
      <header className="flex items-center justify-between gap-3 border-b border-border px-5 py-4">
        <div>
          <h2 className="text-sm font-semibold text-foreground">
            {t('title')}
          </h2>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {t('description')}
          </p>
        </div>
        <div className="flex items-center gap-3 text-right text-xs">
          {/* Used to be a static "target 5m" label, unconnected to any
              real data — this repo's own comment flagged it as neutral
              "until there's a real state to color for". It now shows
              the actual share of this week's replies that landed
              within the threshold (loadResponseTime computes it from
              the same samples the chart is built from), colored
              emerald once it clears a informal 80% bar. */}
          {thresholdMinutes > 0 && data?.thisWeekSlaCompliance != null && (
            <span
              className={
                data.thisWeekSlaCompliance >= 80
                  ? 'rounded-full border border-emerald-500/40 bg-emerald-500/15 px-2 py-0.5 font-medium text-emerald-600 tabular-nums dark:text-emerald-400'
                  : 'rounded-full border border-border bg-muted px-2 py-0.5 font-medium text-muted-foreground tabular-nums'
              }
            >
              {t('slaCompliance', {
                percent: Math.round(data.thisWeekSlaCompliance),
                minutes: thresholdMinutes,
              })}
            </span>
          )}
          {data && (data.thisWeekAvg != null || data.lastWeekAvg != null) && (
            <div>
              <div className="text-muted-foreground">
                {t('thisWeek')}{' '}
                <span className="font-medium text-foreground tabular-nums">
                  {fmt(data.thisWeekAvg)}
                </span>
              </div>
              <div className="text-muted-foreground">
                {t('lastWeek')}{' '}
                <span className="tabular-nums">{fmt(data.lastWeekAvg)}</span>
              </div>
            </div>
          )}
        </div>
      </header>

      <div className="p-5">
        {loading || !data ? (
          <Skeleton className="h-[260px] w-full" />
        ) : !hasData ? (
          <EmptyState
            icon={Clock}
            title={t('noReplies')}
            hint={t('noRepliesHint')}
          />
        ) : (
          <BarChart
            data={chartData}
            index="day"
            categories={[CATEGORY]}
            // 'violet' maps to Tailwind's `fill-violet-500` — matches
            // the brand accent the hand-rolled bars used (#7c3aed).
            colors={['violet']}
            // `toFixed(1)` en cada marca daba etiquetas como "20.0m", que
            // no cabian en los 48px del eje y se recortaban contra el borde
            // del SVG: se perdia el digito de la izquierda, asi que la marca
            // de 20 minutos se leia "0.0m" y el eje entero decia 0/5/0/5/0.
            valueFormatter={(value) =>
              Number.isInteger(value) ? `${value}m` : `${value.toFixed(1)}m`
            }
            showLegend={false}
            yAxisWidth={56}
            // Compact height so the chart sits well inside the card
            // without dominating the row alongside the donut + activity feed.
            className="h-[260px]"
          />
        )}
      </div>
    </section>
  )
}

function fmt(mins: number | null): string {
  if (mins == null) return '—'
  if (mins < 1) return `${Math.max(1, Math.round(mins * 60))}s`
  if (mins < 60) return `${mins.toFixed(1)}m`
  return `${(mins / 60).toFixed(1)}h`
}
