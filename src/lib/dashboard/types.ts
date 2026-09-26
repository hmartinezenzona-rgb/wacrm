// Shared result shapes the dashboard components consume. Centralised
// here so each component stays thin and the page-level loader wires
// them up without type gymnastics.

export interface MetricDelta {
  current: number
  previous: number
}

export interface MetricsBundle {
  activeConversations: MetricDelta
  newContactsToday: MetricDelta
  /** Sum of quoted_source_amount for remittance_operations not yet
   *  completed or cancelled — the successor to the retired
   *  deals/pipeline "open value" metric. */
  operationsInProgressValue: number
  operationsInProgressCount: number
  messagesSentToday: MetricDelta
}

export interface ConversationsSeriesPoint {
  day: string // YYYY-MM-DD local
  incoming: number
  outgoing: number
}

export interface ServiceVolumeSlice {
  serviceType: string
  color: string
  operationCount: number
  volumeGyd: number
  averageTicketGyd: number
}

export interface ServiceVolumeData {
  services: ServiceVolumeSlice[]
  totalVolumeGyd: number
}

/** One non-terminal remittance_operations status, in process order. */
export interface OperationsFunnelStage {
  status: string
  operationCount: number
}

export interface OperationsFunnelData {
  stages: OperationsFunnelStage[]
}

/** Who bills the most and which destination currencies move the most this
 *  month, from completed calculator ledger entries. Period totals and the
 *  per-service profitability live on /resumen's financial close. */
export interface LedgerProfitData {
  topClients: TopClientEntry[]
  byDestinationCurrency: DestinationBreakdownEntry[]
}

/** One row from `cerebro_dashboard_operaciones_envejecidas()` — an
 *  in-flight (non-terminal-status) `remittance_operations` row,
 *  oldest first. `contactName` is null when the operation has no
 *  `contact_id` on record or the joined contact has no name. */
export interface AgedOperation {
  id: string
  conversationId: string
  contactName: string | null
  deliveryMethod: string | null
  /** Known well before `deliveryMethod` in this business's real flow —
   *  coarser (CUP/USD, doesn't distinguish zelle/clasica/tropical
   *  within USD) but real, already-decided information the caller
   *  falls back to when `deliveryMethod` isn't set yet. */
  destinationCurrency: string | null
  quotedSourceAmount: number | null
  status: string
  createdAt: string
}

/** One client's aggregated billing this month. `customerName === null`
 *  means the completed entry carried no identity on record — grouped
 *  together rather than dropped, since it's still real volume. */
export interface TopClientEntry {
  customerName: string | null
  operationCount: number
  facturadoGyd: number
}

/** Aggregated billing this month for one destination currency
 *  (`amount_currency` — the client's requested currency, not the GYD
 *  settlement currency the rest of the ledger widgets show). */
export interface DestinationBreakdownEntry {
  currency: string
  operationCount: number
  facturadoGyd: number
}

export type BusinessInsightsData = Pick<
  LedgerProfitData,
  'topClients' | 'byDestinationCurrency'
>

export interface ResponseTimeBucket {
  /** 0 = Mon … 6 = Sun (Monday-first). */
  dow: number
  /** Average first-response time in minutes. Null means no samples. */
  avgMinutes: number | null
  samples: number
}

export interface ResponseTimeSummary {
  buckets: ResponseTimeBucket[]
  thisWeekAvg: number | null
  lastWeekAvg: number | null
  /** Share (0-100) of this week's samples answered within the
   *  threshold passed to loadResponseTime. Null means no samples. */
  thisWeekSlaCompliance: number | null
  lastWeekSlaCompliance: number | null
}

export type ActivityKind =
  | 'message'
  | 'broadcast'
  | 'automation'
  | 'contact'

export interface ActivityItem {
  id: string
  kind: ActivityKind
  /** Primary line of text rendered in the feed. Pre-formatted. */
  text: string
  /** ISO timestamp the item happened at, drives relative-time + sort. */
  at: string
  /** Optional deep-link for the whole row (not all items have a target). */
  href?: string
}
