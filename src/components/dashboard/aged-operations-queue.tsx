"use client"

import { CheckCircle2 } from 'lucide-react'
import Link from 'next/link'
import { useTranslations } from 'next-intl'
import type { AgedOperation } from '@/lib/dashboard/types'
import { humanizeAge } from '@/lib/dashboard/date-utils'
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

interface AgedOperationsQueueProps {
  data: AgedOperation[] | null
  loading: boolean
}

// Ledger/operation amounts shown here are always GYD
// (`quoted_source_amount`, the client's GYD deposit) — same rule as
// every other financial widget on this dashboard.
const LEDGER_CURRENCY = 'GYD'

// Mirrors `calculator_service_for_operation()` (migration 104) exactly
// — the same delivery_method -> CUP/ZELLE/CLASICA/TROPICAL mapping the
// calculator ledger uses (see ServiceProfitabilityTable). No display
// mapping for raw `delivery_method` existed anywhere on this dashboard
// before this widget, so this reuses the ledger's own taxonomy rather
// than inventing a new one.
const DELIVERY_METHOD_SERVICE: Record<string, string> = {
  cuban_card: 'CUP',
  multiple_distribution: 'CUP',
  zelle: 'ZELLE',
  clasica: 'CLASICA',
  tropical: 'TROPICAL',
}

// `deliveryMethod` is almost never set yet on a non-terminal operation
// in this business's real flow (verified against live data: 0 of 4
// in-flight ops had it, vs 8 of 11 completed ones — it only resolves
// late, at/near completion). `destinationCurrency` (CUP/USD) IS already
// known this early (verified: all 4 in-flight ops had it) — coarser
// than the delivery-method service (doesn't distinguish zelle/clasica/
// tropical within USD) but real, already-decided information, so it's
// a real fallback, not a guess.
function serviceLabel(deliveryMethod: string | null, destinationCurrency: string | null): string {
  if (deliveryMethod) return DELIVERY_METHOD_SERVICE[deliveryMethod] ?? deliveryMethod
  if (destinationCurrency) return destinationCurrency
  return '—'
}

/**
 * The oldest in-flight (non-terminal-status) remittance operations,
 * from `cerebro_dashboard_operaciones_envejecidas()` — "needs action
 * now", so this renders right after the business snapshot hero and
 * before quick actions. A `contactName === null` row (no `contact_id`
 * on record, or a contact with no name) shows the `unknownClient`
 * fallback — this RPC has no phone to fall back to further. Zero rows
 * is a genuinely good state (nothing stuck), not an error/warning.
 */
export function AgedOperationsQueue({ data, loading }: AgedOperationsQueueProps) {
  const t = useTranslations('Dashboard.agedOperations')
  const stageT = useTranslations('Dashboard.operationsFunnel')
  const rows = data ?? []

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
          <EmptyState icon={CheckCircle2} title={t('noneStuck')} hint={t('noneStuckHint')} />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t('client')}</TableHead>
                <TableHead>{t('service')}</TableHead>
                <TableHead className="text-right">{t('amount')}</TableHead>
                <TableHead>{t('status')}</TableHead>
                <TableHead className="text-right">{t('age')}</TableHead>
                <TableHead className="text-right">{t('action')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="font-medium text-foreground">
                    {row.contactName || t('unknownClient')}
                  </TableCell>
                  <TableCell className="text-muted-foreground">
                    {serviceLabel(row.deliveryMethod, row.destinationCurrency)}
                  </TableCell>
                  <TableCell className="text-right tabular-nums text-foreground">
                    {row.quotedSourceAmount === null
                      ? '—'
                      : formatCurrencyShort(row.quotedSourceAmount, LEDGER_CURRENCY)}
                  </TableCell>
                  <TableCell className="text-muted-foreground">
                    {stageT(`stage.${row.status}`)}
                  </TableCell>
                  <TableCell className="text-right tabular-nums text-muted-foreground">
                    {humanizeAge(row.createdAt)}
                  </TableCell>
                  <TableCell className="text-right">
                    <Link
                      href={`/inbox?c=${row.conversationId}`}
                      className="text-sm font-medium text-primary hover:underline"
                    >
                      {t('openChat')}
                    </Link>
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
