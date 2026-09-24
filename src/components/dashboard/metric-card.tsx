import { ArrowDown, ArrowUp, Minus } from 'lucide-react'
import type { ComponentType } from 'react'
import { cn } from '@/lib/utils'

interface MetricCardProps {
  title: string
  /** Pre-formatted value for display (e.g. "42" or "$1,250"). */
  value: string
  icon: ComponentType<{ className?: string }>
  /**
   * Delta-mode secondary row: arrow + delta text. Omit when the metric
   * doesn't have a sensible comparison (e.g. total pipeline value).
   */
  delta?: {
    /** Positive / negative / zero drives arrow + color. */
    sign: number
    /** Pre-formatted delta, e.g. "+3 vs yesterday". */
    label: string
  }
  /** Used instead of `delta` when the metric has a static subtitle. */
  subtitle?: string
  /**
   * Reserved status color for the icon badge, for a value that IS a
   * good/bad signal (e.g. profit). Omit (default 'neutral') for a plain
   * count or magnitude — status color is never decorative, and doesn't
   * follow the account's selectable brand theme (`--primary` can be red
   * under the "rose" theme), so a status tile stays readable as
   * good/bad regardless of theme.
   */
  tone?: 'neutral' | 'good' | 'bad'
}

const TONE_BADGE_CLASSES: Record<NonNullable<MetricCardProps['tone']>, string> = {
  neutral: 'bg-muted text-muted-foreground',
  good: 'bg-emerald-500/10 text-emerald-600 dark:text-emerald-400',
  bad: 'bg-red-500/10 text-red-400',
}

// The value itself, not just the icon badge, has to carry the status
// color — that's the number people actually look at.
const TONE_VALUE_CLASSES: Record<NonNullable<MetricCardProps['tone']>, string> = {
  neutral: 'text-foreground',
  good: 'text-emerald-600 dark:text-emerald-400',
  bad: 'text-red-400',
}

export function MetricCard({
  title,
  value,
  icon: Icon,
  delta,
  subtitle,
  tone = 'neutral',
}: MetricCardProps) {
  return (
    <div className="rounded-xl border border-border bg-card tarjeta-elevada p-5">
      <div className="flex items-start justify-between">
        <p className="text-sm font-medium text-muted-foreground">{title}</p>
        <div
          className={cn(
            'flex h-8 w-8 items-center justify-center rounded-lg',
            TONE_BADGE_CLASSES[tone],
          )}
        >
          <Icon className="h-4 w-4" />
        </div>
      </div>
      <p className={cn('mt-3 text-[28px] leading-none font-bold tabular-nums', TONE_VALUE_CLASSES[tone])}>
        {value}
      </p>
      {delta ? <DeltaRow sign={delta.sign} label={delta.label} /> : subtitle ? (
        <p className="mt-2 text-sm text-muted-foreground">{subtitle}</p>
      ) : null}
    </div>
  )
}

function DeltaRow({ sign, label }: { sign: number; label: string }) {
  const tone =
    sign > 0
      ? 'text-primary'
      : sign < 0
      ? 'text-red-400'
      : 'text-muted-foreground'
  const Arrow = sign > 0 ? ArrowUp : sign < 0 ? ArrowDown : Minus
  return (
    <div className={cn('mt-2 flex items-center gap-1 text-sm', tone)}>
      <Arrow className="h-4 w-4" aria-hidden />
      <span className="tabular-nums">{label}</span>
    </div>
  )
}
