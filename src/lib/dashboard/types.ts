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

/** facturado - invertido = retorno, summed over completed calculator
 *  ledger entries in one period. */
export interface LedgerProfitBucket {
  operationCount: number
  facturadoGyd: number
  invertidoGyd: number
  retornoGyd: number
}

export interface LedgerProfitData {
  today: LedgerProfitBucket
  thisWeek: LedgerProfitBucket
  thisMonth: LedgerProfitBucket
  /** Top clients / destination-currency breakdown this month — computed
   *  from the SAME fetched entries as the buckets above, not a second
   *  query, so BusinessInsights and LedgerProfitSummary share one
   *  round trip instead of duplicating it. */
  topClients: TopClientEntry[]
  byDestinationCurrency: DestinationBreakdownEntry[]
  /** Per-service (CUP/ZELLE/CLASICA/TROPICAL) profitability this
   *  month — same SAME fetched entries as everything else above,
   *  aggregated by `entry.service` instead of by time bucket or
   *  client/currency. See `serviceProfitabilityFrom`. */
  serviceProfitability: ServiceProfitabilityRow[]
}

/** One service's aggregated billing/profit this month (the ledger's
 *  own CUP/ZELLE/CLASICA/TROPICAL taxonomy — NOT
 *  `remittance_operations.service_type`, an unrelated taxonomy). */
export interface ServiceProfitabilityRow {
  service: string
  operationCount: number
  facturadoGyd: number
  retornoGyd: number
  /** `retornoGyd / facturadoGyd * 100`, `null` at zero facturado
   *  (rendered as "—", never NaN/Infinity). */
  margenPct: number | null
  ticketMedioGyd: number
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
