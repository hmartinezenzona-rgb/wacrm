"use client"

import { Workflow } from 'lucide-react'
import type { OperationsFunnelData } from '@/lib/dashboard/types'
import { EmptyState } from './empty-state'
import { Skeleton } from './skeleton'

interface OperationsFunnelProps {
  data: OperationsFunnelData | null
  loading: boolean
}

import { useTranslations } from 'next-intl'

// Six fixed opacity steps, one per stage, purely as a flow-direction
// cue layered on top of the real signal (bar width = actual count).
// Same primary color throughout — this is one process, not six
// categories, so a categorical palette (like the service-volume
// donut's) would be the wrong metaphor here.
const STAGE_OPACITY = [1, 0.85, 0.7, 0.55, 0.4, 0.25]

export function OperationsFunnel({ data, loading }: OperationsFunnelProps) {
  const t = useTranslations('Dashboard.operationsFunnel')
  const hasAny = data?.stages.some((s) => s.operationCount > 0) ?? false
  // Widest bar = whichever stage currently holds the most operations,
  // not the sum — a funnel compares stages to each other, not to a
  // grand total that no single stage could ever reach.
  const maxCount = data ? Math.max(1, ...data.stages.map((s) => s.operationCount)) : 1

  return (
    <section className="rounded-xl border border-border bg-card tarjeta-elevada">
      <header className="border-b border-border px-5 py-4">
        <h2 className="text-sm font-semibold text-foreground">{t('title')}</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">{t('description')}</p>
      </header>

      <div className="p-5">
        {loading || !data ? (
          <Skeleton className="h-56 w-full" />
        ) : !hasAny ? (
          <EmptyState
            icon={Workflow}
            title={t('noOperations')}
            hint={t('noOperationsHint')}
          />
        ) : (
          <ul className="space-y-2.5">
            {data.stages.map((stage, i) => {
              const widthPct = Math.max(
                4, // a visible sliver even at 0, so the row/label never disappears
                Math.round((100 * stage.operationCount) / maxCount),
              )
              return (
                <li key={stage.status} className="flex items-center gap-3">
                  <span className="w-36 shrink-0 truncate text-xs text-muted-foreground">
                    {t(`stage.${stage.status}`)}
                  </span>
                  <div className="h-6 flex-1 rounded-md bg-muted">
                    <div
                      className="h-6 rounded-md bg-primary transition-all"
                      style={{ width: `${widthPct}%`, opacity: STAGE_OPACITY[i] ?? 1 }}
                    />
                  </div>
                  <span className="w-6 shrink-0 text-right text-xs font-medium tabular-nums text-foreground">
                    {stage.operationCount}
                  </span>
                </li>
              )
            })}
          </ul>
        )}
      </div>
    </section>
  )
}
