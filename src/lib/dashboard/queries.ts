import type { SupabaseClient } from '@supabase/supabase-js'
import {
  daysAgoStart,
  DOW_SHORT_MON_FIRST,
  lastNDayKeys,
  localDayKey,
  mondayIndex,
  startOfLocalDay,
} from './date-utils'
import type {
  ActivityItem,
  AgedOperation,
  ConversationsSeriesPoint,
  LedgerProfitData,
  MetricsBundle,
  ResponseTimeBucket,
  ResponseTimeSummary,
  OperationsFunnelData,
  ServiceVolumeData,
  ServiceVolumeSlice,
} from './types'
import {
  LEDGER_ENTRY_COLUMNS,
  mapLedgerEntry,
  type LedgerEntryRow,
} from '@/lib/calculator/ledger-read-model'
import { destinationBreakdownFrom, topClientsFrom } from './business-insights'

// ------------------------------------------------------------
// All client-side aggregation. RLS scopes every query to the
// signed-in user automatically, so we never pass user_id explicitly
// here. Perf is acceptable for the current scale (low thousands of
// messages) — if a tenant's dataset outgrows this, we'd migrate the
// heavy aggregations to SQL RPCs. Noted in the PR.
// ------------------------------------------------------------

type DB = SupabaseClient

// --- 1. Metric cards ---------------------------------------------------

export async function loadMetrics(db: DB): Promise<MetricsBundle> {
  const todayStart = startOfLocalDay().toISOString()
  const yesterdayStart = daysAgoStart(1).toISOString()

  const [
    openConvCur,
    newConvToday,
    newConvYesterday,
    newContactsToday,
    newContactsYesterday,
    operationsInProgress,
    messagesToday,
    messagesYesterday,
  ] = await Promise.all([
    db.from('conversations').select('id', { count: 'exact', head: true }).eq('status', 'open'),
    db
      .from('conversations')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'open')
      .gte('created_at', todayStart),
    db
      .from('conversations')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'open')
      .gte('created_at', yesterdayStart)
      .lt('created_at', todayStart),
    db.from('contacts').select('id', { count: 'exact', head: true }).gte('created_at', todayStart),
    db
      .from('contacts')
      .select('id', { count: 'exact', head: true })
      .gte('created_at', yesterdayStart)
      .lt('created_at', todayStart),
    db.rpc('cerebro_dashboard_operaciones_en_curso'),
    db
      .from('messages')
      .select('id', { count: 'exact', head: true })
      .eq('sender_type', 'agent')
      .gte('created_at', todayStart),
    db
      .from('messages')
      .select('id', { count: 'exact', head: true })
      .eq('sender_type', 'agent')
      .gte('created_at', yesterdayStart)
      .lt('created_at', todayStart),
  ])

  const operationsInProgressRow = (
    (operationsInProgress.data ?? [])[0] as
      | { operaciones: number; volumen_gyd: number }
      | undefined
  )

  return {
    activeConversations: {
      current: openConvCur.count ?? 0,
      // "vs yesterday" on a current-state count has no clean answer
      // without snapshots — we show the delta in NEW open conversations
      // today vs yesterday. That's the business-meaningful daily signal.
      previous: (newConvToday.count ?? 0) - (newConvYesterday.count ?? 0),
    },
    newContactsToday: {
      current: newContactsToday.count ?? 0,
      previous: newContactsYesterday.count ?? 0,
    },
    operationsInProgressValue: operationsInProgressRow?.volumen_gyd ?? 0,
    operationsInProgressCount: operationsInProgressRow?.operaciones ?? 0,
    messagesSentToday: {
      current: messagesToday.count ?? 0,
      previous: messagesYesterday.count ?? 0,
    },
  }
}

// --- 2. Conversations over time ---------------------------------------

export async function loadConversationsSeries(
  db: DB,
  rangeDays: number,
): Promise<ConversationsSeriesPoint[]> {
  const start = daysAgoStart(rangeDays - 1).toISOString()
  const { data, error } = await db
    .from('messages')
    .select('created_at, sender_type')
    .gte('created_at', start)
    .order('created_at', { ascending: true })
  if (error) throw error

  const keys = lastNDayKeys(rangeDays)
  const buckets = new Map<string, { incoming: number; outgoing: number }>()
  for (const k of keys) buckets.set(k, { incoming: 0, outgoing: 0 })

  for (const row of (data ?? []) as { created_at: string; sender_type: string }[]) {
    const key = localDayKey(row.created_at)
    const bucket = buckets.get(key)
    if (!bucket) continue
    if (row.sender_type === 'customer') bucket.incoming += 1
    else bucket.outgoing += 1 // agent + bot both count as outgoing
  }

  return keys.map((day) => ({ day, ...(buckets.get(day) ?? { incoming: 0, outgoing: 0 }) }))
}

// --- 3b. Service volume donut -------------------------------------------

// The 6 real `service_type` values (migration 046's CHECK constraint) mapped
// onto the design system's 5 theme-aware categorical tokens. `mexico` and
// `traduccion` are the two most tangential to the core remittance business
// (a corridor variant and a translation add-on, respectively), so they
// share --chart-5; `traduccion`'s slice is rendered at reduced opacity in
// the component to stay visually distinguishable from `mexico`.
const SERVICE_TYPE_COLORS: Record<string, string> = {
  remesa: 'var(--chart-1)',
  combo: 'var(--chart-2)',
  recarga: 'var(--chart-3)',
  visa: 'var(--chart-4)',
  mexico: 'var(--chart-5)',
  traduccion: 'var(--chart-5)',
}
const DEFAULT_SERVICE_COLOR = 'var(--chart-5)'

export async function loadServiceVolume(db: DB): Promise<ServiceVolumeData> {
  const { data, error } = await db.rpc('cerebro_dashboard_volumen_por_servicio')
  if (error) throw error

  const rows = (data ?? []) as {
    service_type: string
    operaciones: number
    volumen_gyd: number
    ticket_medio_gyd: number
  }[]

  const services: ServiceVolumeSlice[] = rows.map((r) => ({
    serviceType: r.service_type,
    color: SERVICE_TYPE_COLORS[r.service_type] ?? DEFAULT_SERVICE_COLOR,
    operationCount: r.operaciones,
    volumeGyd: r.volumen_gyd,
    averageTicketGyd: r.ticket_medio_gyd,
  }))

  return {
    services,
    totalVolumeGyd: services.reduce((sum, s) => sum + s.volumeGyd, 0),
  }
}

// --- 3b. Operations funnel ----------------------------------------------

export async function loadOperationsFunnel(db: DB): Promise<OperationsFunnelData> {
  const { data, error } = await db.rpc('cerebro_dashboard_embudo_operaciones')
  if (error) throw error

  const rows = (data ?? []) as { status: string; operaciones: number }[]

  return {
    stages: rows.map((r) => ({
      status: r.status,
      operationCount: r.operaciones,
    })),
  }
}

// --- 3c. Calculator ledger profit (facturado/invertido/retorno) --------

export async function loadLedgerProfit(db: DB): Promise<LedgerProfitData> {
  const now = new Date()
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1)

  // `remittance_calculator_entries` carries a real RLS SELECT policy
  // (is_account_member) — unlike remittance_operations, which needed a
  // SECURITY DEFINER RPC for every other dashboard widget in this file.
  // Direct table read, same as loadMetrics/loadConversationsSeries.
  const { data, error } = await db
    .from('remittance_calculator_entries')
    .select(LEDGER_ENTRY_COLUMNS)
    .eq('source', 'completed_operation')
    .neq('status', 'void')
    .gte('entry_date', localDayKey(monthStart))
  if (error) throw error

  const entries = ((data ?? []) as LedgerEntryRow[]).map(mapLedgerEntry)

  // The period totals (today/week/month) and the per-service profitability
  // this used to compute now live on /resumen's financial close
  // (crm_cierre_financiero, migration 121); the dashboard keeps only who
  // bills the most and which destination currencies move the most.
  return {
    topClients: topClientsFrom(entries),
    byDestinationCurrency: destinationBreakdownFrom(entries),
  }
}

// --- 3d. Aged / stuck operations queue ----------------------------------

export async function loadAgedOperations(db: DB): Promise<AgedOperation[]> {
  const { data, error } = await db.rpc('cerebro_dashboard_operaciones_envejecidas')
  if (error) throw error

  const rows = (data ?? []) as {
    id: string
    conversation_id: string
    contact_name: string | null
    delivery_method: string | null
    destination_currency: string | null
    quoted_source_amount: number | string | null
    status: string
    created_at: string
  }[]

  return rows.map((r) => ({
    id: r.id,
    conversationId: r.conversation_id,
    contactName: r.contact_name,
    deliveryMethod: r.delivery_method,
    destinationCurrency: r.destination_currency,
    quotedSourceAmount:
      r.quoted_source_amount === null ? null : Number(r.quoted_source_amount),
    status: r.status,
    createdAt: r.created_at,
  }))
}

// --- 4. Response time by day of week ----------------------------------

export async function loadResponseTime(
  db: DB,
  thresholdMinutes = 5,
): Promise<ResponseTimeSummary> {
  // Pull the last 14 days of messages in one shot, then walk per
  // conversation to find each "first inbound" → "first subsequent
  // outbound" pair. 14 days gives us both "this week" + "last week"
  // with enough overlap if the user opens the dashboard late on a
  // Monday.
  const fourteenDaysAgo = daysAgoStart(13).toISOString()
  const { data, error } = await db
    .from('messages')
    .select('conversation_id, sender_type, created_at')
    .gte('created_at', fourteenDaysAgo)
    .order('conversation_id', { ascending: true })
    .order('created_at', { ascending: true })
  if (error) throw error

  const rows = (data ?? []) as {
    conversation_id: string
    sender_type: string
    created_at: string
  }[]

  // Group per conversation, pair unreplied customer messages with the
  // next outbound message from the agent/bot. A single customer message
  // can only count once (avoids inflating averages if the customer
  // double-messages while the agent takes time to reply).
  interface Sample {
    customerAt: Date
    responseAt: Date
  }
  const samples: Sample[] = []

  let currentConv = ''
  let pendingCustomer: Date | null = null
  for (const row of rows) {
    if (row.conversation_id !== currentConv) {
      currentConv = row.conversation_id
      pendingCustomer = null
    }
    const ts = new Date(row.created_at)
    if (row.sender_type === 'customer') {
      if (!pendingCustomer) pendingCustomer = ts
    } else if (pendingCustomer) {
      samples.push({ customerAt: pendingCustomer, responseAt: ts })
      pendingCustomer = null
    }
  }

  const now = new Date()
  const thisWeekStart = daysAgoStart(mondayIndex(now))
  const lastWeekStart = daysAgoStart(mondayIndex(now) + 7)

  // Per-day-of-week buckets, averaged over both weeks' worth of data
  // so each bar has more samples to stand on. If a day has no samples
  // its avgMinutes stays null and the chart renders the bar muted.
  const byDow = new Map<number, number[]>()
  for (let i = 0; i < 7; i++) byDow.set(i, [])
  const thisWeekMins: number[] = []
  const lastWeekMins: number[] = []

  for (const s of samples) {
    const diffMin = (s.responseAt.getTime() - s.customerAt.getTime()) / 60_000
    if (diffMin < 0) continue
    const dow = mondayIndex(s.customerAt)
    byDow.get(dow)!.push(diffMin)
    if (s.customerAt >= thisWeekStart) {
      thisWeekMins.push(diffMin)
    } else if (s.customerAt >= lastWeekStart && s.customerAt < thisWeekStart) {
      lastWeekMins.push(diffMin)
    }
  }

  const avg = (arr: number[]) =>
    arr.length === 0 ? null : arr.reduce((a, b) => a + b, 0) / arr.length

  // Share of samples answered at or under the threshold, as a 0-100
  // percentage. This is what the header pill shows now — "X% within
  // Nm" reads as compliance at a glance, which a raw average doesn't:
  // an average can sit under the target while a chunk of replies still
  // blow past it. Matches how Freshchat/Zendesk surface SLA status.
  const slaCompliance = (arr: number[]) =>
    arr.length === 0
      ? null
      : (100 * arr.filter((m) => m <= thresholdMinutes).length) / arr.length

  const buckets: ResponseTimeBucket[] = Array.from({ length: 7 }, (_, dow) => {
    const samples = byDow.get(dow) ?? []
    return {
      dow,
      avgMinutes: avg(samples),
      samples: samples.length,
    }
  })

  // Silence unused-label warnings — keep the arrays explicitly named
  // for readability above.
  void DOW_SHORT_MON_FIRST

  return {
    buckets,
    thisWeekAvg: avg(thisWeekMins),
    lastWeekAvg: avg(lastWeekMins),
    thisWeekSlaCompliance: slaCompliance(thisWeekMins),
    lastWeekSlaCompliance: slaCompliance(lastWeekMins),
  }
}

// --- 5. Activity feed --------------------------------------------------

export async function loadActivity(db: DB, limit = 20): Promise<ActivityItem[]> {
  // Pull ~10 from each source (plenty of headroom after merge-sort),
  // then interleave by timestamp. The individual per-table limits
  // keep the payload small; the final limit is enforced after sort.
  const [msgs, contacts, broadcasts, autoLogs] = await Promise.all([
    db
      .from('messages')
      .select('id, content_text, sender_type, created_at, conversation_id, conversations(contact_id, contacts(name, phone))')
      .eq('sender_type', 'customer')
      .order('created_at', { ascending: false })
      .limit(10),
    db
      .from('contacts')
      .select('id, name, phone, created_at')
      .order('created_at', { ascending: false })
      .limit(10),
    db
      .from('broadcasts')
      .select('id, name, status, total_recipients, created_at')
      .order('created_at', { ascending: false })
      .limit(5),
    db
      .from('automation_logs')
      .select('id, trigger_event, status, created_at, automation:automations(name), contact:contacts(name, phone)')
      .order('created_at', { ascending: false })
      .limit(10),
  ])

  const items: ActivityItem[] = []

  // PostgREST returns nested selections as arrays by default, even when
  // the foreign key is 1:1. We normalise by taking [0] on each level.
  for (const m of (msgs.data ?? []) as unknown as Array<{
    id: string
    content_text: string | null
    created_at: string
    conversation_id: string
    conversations:
      | { contact_id: string | null; contacts: { name: string | null; phone: string }[] | { name: string | null; phone: string } | null }[]
      | { contact_id: string | null; contacts: { name: string | null; phone: string }[] | { name: string | null; phone: string } | null }
      | null
  }>) {
    const conv = Array.isArray(m.conversations) ? m.conversations[0] : m.conversations
    const contact = Array.isArray(conv?.contacts) ? conv?.contacts[0] : conv?.contacts
    const who = contact?.name || contact?.phone || 'Unknown'
    items.push({
      id: `msg-${m.id}`,
      kind: 'message',
      text: `New message from ${who}`,
      at: m.created_at,
      href: `/inbox?c=${m.conversation_id}`,
    })
  }

  for (const c of (contacts.data ?? []) as Array<{ id: string; name: string | null; phone: string; created_at: string }>) {
    items.push({
      id: `contact-${c.id}`,
      kind: 'contact',
      text: `New contact: ${c.name || c.phone}`,
      at: c.created_at,
      href: '/contacts',
    })
  }

  for (const b of (broadcasts.data ?? []) as Array<{
    id: string
    name: string
    status: string
    total_recipients: number
    created_at: string
  }>) {
    const label =
      b.status === 'sent'
        ? `sent to ${b.total_recipients} contacts`
        : `${b.status} (${b.total_recipients} recipients)`
    items.push({
      id: `broadcast-${b.id}`,
      kind: 'broadcast',
      text: `Broadcast "${b.name}" ${label}`,
      at: b.created_at,
      href: '/broadcasts',
    })
  }

  for (const l of (autoLogs.data ?? []) as unknown as Array<{
    id: string
    trigger_event: string
    status: string
    created_at: string
    automation: { name: string }[] | { name: string } | null
    contact: { name: string | null; phone: string }[] | { name: string | null; phone: string } | null
  }>) {
    const automation = Array.isArray(l.automation) ? l.automation[0] : l.automation
    const contact = Array.isArray(l.contact) ? l.contact[0] : l.contact
    const who = contact?.name || contact?.phone || 'a contact'
    const autoName = automation?.name || 'Automation'
    items.push({
      id: `auto-${l.id}`,
      kind: 'automation',
      text: `Automation "${autoName}" ${l.status === 'failed' ? 'failed for' : 'triggered for'} ${who}`,
      at: l.created_at,
    })
  }

  return items
    .sort((a, b) => (a.at > b.at ? -1 : a.at < b.at ? 1 : 0))
    .slice(0, limit)
}
