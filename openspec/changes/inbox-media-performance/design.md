# Design: Inbox thread and WhatsApp media performance

## Technical Approach

The change keeps the current client-rendered inbox and private `chat-media` bucket and fixes the five verified root causes in a fixed order. User-visible wins come first and need no schema change. Schema, ingest and backfill come after them.

1. A same-origin GET route returns one keyset page of messages together with the signed URLs for that page. The browser seeds its existing signed-URL cache from the response, so the first paint needs no second round trip (proposal root cause 1).
2. Bubbles use the signed URL first and fall back to the byte proxy only when signing fails. Audio and video do not preload. Images are lazy and reserve their space (root cause 2, part of 5).
3. Realtime is split. Message INSERTs stay account-wide, because the chat sound and the list preview depend on them. Message UPDATEs are filtered to the open conversation. List and thread state are patched by id and return the same reference when nothing changed (root cause 4).
4. The thread is virtualized with `react-virtuoso`, using a prepend-safe item model (root cause 5).
5. Migration 400 adds nullable media metadata columns and a sweeper claim function. Ingest writes thumbnails with `sharp`. Readers prefer the thumbnail and fall back to `media_url`.
6. Ingest inserts the row first as `pending`, with `media_url` set to today's legacy proxy URL. It then settles the media to `ready` or `failed`, and only then runs the bot-facing tail (root cause 3). A sweeper inside the existing cron worker completes rows that a process restart interrupted.
7. A resumable backfill fills the metadata and thumbnails for history.

No specs exist yet for this change (`openspec/changes/inbox-media-performance/specs/` is absent). This design follows the proposal. Where it deviates, it says so explicitly (see "Deviations from the proposal").

### Facts verified in code that shape the design

- `processWebhook` already runs entirely inside one `after()` (`webhook/route.ts:244`). "Decoupling" therefore means reordering work inside that callback. No second background mechanism is needed.
- Production runs `next start` from `output: "standalone"` (`next.config.ts:69`). The Next 16.4.6 docs (`02-guides/self-hosting.md`, section `after`) state that pending `after()` callbacks run to completion on SIGTERM/SIGINT if the platform gives a drain period. A hard kill or a crash still loses them, which is why the sweeper exists.
- **There is no `messages`-level dedupe today.** There is no unique index on `messages.message_id` (migration 009 states that Meta ids repeat across numbers), and the webhook has no pre-insert check. Only the durable outbox skips a wamid that the Cerebro already saw. The proposal's "dedupe stays on `messages[].id`" premise is therefore wrong. This design adds an explicit guard (ADR-7).
- The customer-side AFTER INSERT triggers on `messages` (`zzz_messages_reactivar_no_negocio`, migration 364) do not read `media_url`. The other INSERT triggers (171, 132, 296) only fire for `sender_type = 'agent'`. Inserting a customer media row early therefore changes no trigger behaviour.
- The legacy route `/api/whatsapp/media/<mediaId>` authorises by `media_url = '/api/whatsapp/media/<id>'` OR `media_url LIKE '%wa-<id>.%'`. A row stored with the proxy URL while pending is servable by that route, so it is also correct as the `failed` value.
- The account-wide `messages` INSERT handler in `inbox/page.tsx:213-275` drives three things: the chat sound (`chat-sound-gate.ts`, which needs `sender_type`, `conversation_id` and `created_at` of each customer message in a non-active conversation), the list preview and unread counter, and the hydration of unknown conversations.
- `jumpToMessage` uses `document.querySelector('[data-message-id]')` (`message-thread.tsx:554`), which cannot work once rows are virtualized.
- A resync currently resets `olderMessages` to `[]` (`message-thread.tsx:316`), so loaded history shrinks from the top on every resync.
- `MessageBubble` receives a new closure and a new `reply` object on every render (`message-thread.tsx:1267-1299`). `React.memo` alone would have no effect.
- No `cacheComponents` is configured. Route Handlers are not cached by default (`01-getting-started/15-route-handlers.md`, section "Caching"), and reading `request.url` keeps them dynamic.

## Architecture Decisions

### ADR-1: Server thread read route

**Choice**: `GET /api/inbox/messages` in `src/app/api/inbox/messages/route.ts`.

- Query: `conversationId` (uuid, required), `limit` (1-100, default 50), and an optional cursor pair `beforeCreatedAt` + `beforeId`. Both cursor fields are present or both are absent.
- Auth: `requireRole('viewer')` from `@/lib/auth/account`. It verifies the session cookie (`getClaims`), loads the profile and returns the RLS-scoped `ctx.supabase`. All reads use `ctx.supabase` and never the service role, so RLS stays authoritative.
- Membership: in parallel with the page query, the route runs `conversations.select('id').eq('id', conversationId).eq('account_id', ctx.accountId).maybeSingle()`. If no row comes back, the route returns 404 and the page is discarded.
- Page query: the same keyset as today. The query is `eq('conversation_id', id)`, plus `.or('created_at.lt.<c>,and(created_at.eq.<c>,id.lt.<i>))')` when a cursor is present, ordered `created_at DESC, id DESC`, with `limit + 1`. The extra row sets `hasMore` exactly, which replaces today's `rows.length === PAGE` guess. The response reverses the rows to chronological ascending order, ready for rendering.
- Signing: the route collects `media_url` values of the page (and, from slice 5b on, the proxy form of `media_thumb_path`) and calls one shared helper `signChatMediaUrls(urls, accountId)`. The helper is extracted from the sign route into `src/lib/storage/chat-media-server.ts`. It keeps today's gate: `parseChatMediaPath` plus `isChatMediaPathOfAccount`. A foreign or unparseable path is skipped and logged, never signed, and `createSignedUrls` runs once per page with the 3,600 s TTL.

**Alternatives considered**:
- Reuse `assertChatMediaAccount`. Rejected for the batch: it throws on the first foreign path, so one corrupt row would fail the whole page. It uses the same predicate. The skip semantics match today's sign route exactly.
- RSC streaming. Rejected, as in the proposal: JSON gives the same round-trip win and keeps the client thread intact.
- A POST body. Rejected: this is a read with no body, and GET keeps it out of any future mutation guard.

**Rationale**: One request returns both the rows and their URLs, so images start as soon as the JSON parses. RLS plus the explicit account check is at least as strict as the current client read, and the signing gate is byte-identical to the sign route.

**Cursor validation (injection guard)**: cursor values are interpolated into a PostgREST `or=` filter string. `beforeId` must match `UUID_RE`. `beforeCreatedAt` must match `^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}(:?\d{2})?)$`, which rules out commas, parentheses and dots outside the fraction. The route **must not** normalise the cursor with `new Date().toISOString()`: that truncates microseconds to milliseconds, and the keyset would then skip or repeat messages that share a millisecond. The client sends back the raw `created_at` string it received.

**Error shapes** (all `{ error: string }`, `Cache-Control: private, no-store`):

| Status | When |
|---|---|
| 400 | missing or invalid `conversationId`, `limit` out of range, only one cursor field present, cursor fails its regex |
| 401 / 403 | `toErrorResponse` from `requireRole` (no session, no profile, role below viewer) |
| 404 | conversation not found in the caller's account |
| 500 | page query error (logged as `[inbox messages] page query failed`) |

A signing failure is **not** an error. The route returns 200 with `signed: {}` and logs once. The client then goes through the refresh path and, if that fails too, the proxy. This is today's fail-safe.

### ADR-2: Signed URL lifecycle on the client

**Choice**: one module-level cache in `src/lib/storage/signed-media.ts`, keyed by the stored URL string. This is the same key the sign route returns. Three new exports:

- `seedSignedMedia(signed: Record<string,string>, expiresInSeconds: number, receivedAt = Date.now())` writes entries with `expiresAt = receivedAt + expiresIn*1000`. Using the receive time is conservative: it is later than the moment the server signed, so the margin absorbs it.
- `peekSignedMediaSrc(url): string | null` returns a fresh cached URL synchronously, or null.
- `invalidateSignedMedia(url)` drops one entry.

`resolveMediaSrc` is unchanged: on a cache miss or a near-expiry entry (the existing 5-minute `REFRESH_MARGIN_MS`), it batches through `/api/chat-media/sign`, and the proxy is the final fallback. `useMediaSrc` initialises its state from `peekSignedMediaSrc(url)` and skips the async resolve when the peek is fresh. A seeded bubble therefore renders its signed `src` on the **first** render, with no null-then-src flash.

The thread calls `seedSignedMedia` **before** `onMessagesLoaded(rows)` and before prepending an older page.

Refresh triggers:
1. Cache miss: realtime-inserted rows, and rows whose `media_url` changed from proxy to stored on `pending` to `ready`.
2. Remount after virtualization scroll with an entry inside the margin.
3. A media element `error` event. The bubble calls `invalidateSignedMedia(url)` and re-resolves **once**. A second error leaves the proxy URL (from the resolve fallback) or the existing "unavailable" state. This covers audio or video opened more than 55 minutes after the page loaded.

TTL stays 3,600 s and the cache lives for the tab session only (nothing persisted).

**Alternatives**: a second cache keyed by path (rejected: two keys for one object, and it breaks the sign route's contract); a proactive refresh timer (rejected: it re-signs media nobody will open; error-driven refresh costs nothing until needed).

### ADR-3: Media rendering in bubbles

Source selection per message, in order:

1. `media_status === 'pending'`: placeholder box with the "downloading" copy (owner open decision 2). From slice 5b on; rows become pending only from 6a.
2. `media_url` is a chat-media URL:
   - image with `media_thumb_path` (slice 5b): `src` = resolve(`chatMediaProxyUrl(media_thumb_path)`); the zoom viewer resolves the original `media_url` only when opened.
   - image without a thumbnail, or video, audio, document: resolve(`media_url`).
3. `media_url` is a legacy `/api/whatsapp/media/<id>`: unchanged (the image blob fetch; audio and video use the URL directly).
4. No `media_url`: the existing `MediaUnavailable`. `failed` rows keep the legacy proxy URL, so they follow rule 3 (today's behaviour). The "could not download" copy appears only if that load errors.

Rules:
- **No proxy as the first source.** `resolvedMedia ?? toChatMediaSrc(media_url)` is removed for video, audio and documents. While the source is unresolved, render a sized placeholder (video and audio) or a link without `href` (document). The proxy appears only as `resolveMediaSrc`'s fallback value.
- Images: `loading="lazy"`, `decoding="async"`. `width`/`height` attributes come from `media_width`/`media_height` (original dimensions after EXIF orientation, slice 5b) with CSS `h-auto max-h-64 max-w-60 object-cover`. Before 5b, or when null, a fixed reserved box `h-40 w-60` (the existing loading-box size) keeps lazy loading meaningful: zero-height images would all count as in view.
- Audio and video: `preload="none"` for both. Video keeps `controls` and a reserved `w-60 h-40` box. Audio duration shows only after play. This is accepted, and the "metadata" option is recorded as an open question.
- Proxy-fallback rule: the proxy (`/api/chat-media/<path>`) is used if and only if `resolveMediaSrc` could not obtain a fresh signed URL: sign route non-2xx, offline, or the path was not returned in `signed`.
- Thumbnail naming: `account-<uuid>/thumbs/<basename-of-original-without-extension>.webp`. Example: `account-…/1754300000000-wa-123.jpg` becomes `account-…/thumbs/1754300000000-wa-123.webp`. It is deterministic, so the backfill is idempotent. The thumbnail passes `isSafeChatMediaPath`, inherits members-only read (migration 261, first-folder policy) and is deletable by the prefix `account-<uuid>/thumbs/`. Encoding: WebP, longest side 360 px (240 CSS px at 1.5x), quality 65, `.rotate()` for EXIF, first frame only for animated stickers.
- Memoization: a new `ThreadRow` (`src/components/inbox/thread-row.tsx`, `React.memo`) wraps `MessageActions` and `MessageBubble`. It receives `message`, `replyParent?: Message`, `reactions?: MessageReaction[]`, `currentUserId`, `highlighted: boolean`, and **stable** callbacks taking ids: `onReply(message)`, `onReact(messageId, emoji)`, `onTogglePill(messageId, emoji)` and `onJump(messageId)`. The reply label and preview are computed inside the row. `MessageBubble` is exported wrapped in `React.memo` as well.

### ADR-4: Virtualization library is `react-virtuoso` (MIT `Virtuoso` component)

**Choice**: `react-virtuoso` 4.x, the `Virtuoso` component only. The commercial `@virtuoso.dev/message-list` is explicitly **not** used.

Mapping to current thread behaviour:

| Current behaviour | Virtuoso feature |
|---|---|
| Open at bottom | `initialTopMostItemIndex={{ index: 'LAST', align: 'end' }}`, `key={conversationId}` remount on switch |
| Auto-scroll on new tail (`lastScrolledKeyRef` effect) | `followOutput={() => 'auto'}`. This keeps today's behaviour of always following a new tail; resync with an unchanged tail does not scroll, because items are keyed by id. |
| Older page at top (`scrollTop <= 40`) | `startReached={loadOlderMessages}` |
| Keep position after prepend (`prependAnchorRef`) | `firstItemIndex` decreased by the number of prepended items |
| Jump to quoted message | `scrollToIndex({ index, align: 'center', behavior: 'smooth' })` plus a `highlightId` state rendered by `ThreadRow` for 1,600 ms. This replaces the DOM `classList` toggle. |
| Dynamic bubble heights (images, reactions) | built-in ResizeObserver measurement; `computeItemKey={(_, item) => item.id}` |

**Prepend-safe item model** (`src/lib/inbox/thread-items.ts`): items are messages only, one item per message. A day separator is rendered **below** the last message of a day, when the next message falls on another day. The separator for the oldest loaded day is rendered in Virtuoso's `components.Header`. When older messages are prepended, no existing item changes height: the header text changes, the header height stays constant, and the new items carry their own separators. `firstItemIndex` therefore drops by exactly the number of prepended messages, and the anchor is exact. The "loading older" indicator is an absolutely positioned overlay, so it cannot change the header height. `nextFirstItemIndex(prev, prependedCount)` is a pure function, starting at `1_000_000`.

**Resync**: a resync refetches the newest page and merges it by id (the `displayMessages` merge already exists). It no longer clears `olderMessages`; only a `conversationId` change resets history. Virtuoso cannot shrink from the top without a jump, and the current reset is the scroll-loss bug the comments describe.

**Alternatives**: `@tanstack/react-virtual` was rejected. It is headless and smaller, but reverse-chat anchoring, prepend compensation with dynamic heights, follow-output and initial bottom alignment would all be hand-written. Those are exactly the four behaviours at risk, and its prepend jitter with measured items is a known difficulty. Virtuoso ships them as tested primitives, for about 17 kB gzip. A separator-as-item model was also rejected: separators move between items on a same-day prepend, so the `firstItemIndex` delta is off by one item and the view jumps.

**To verify at install**: the peer range accepts React 19.2, and the `scrollToIndex` index space when `firstItemIndex` is set (absolute or 0-based). A RED test on `thread-items.ts`'s `indexOfMessage(items, id, firstItemIndex)` pins whichever the library expects. The implementer confirms it against the installed package's README before GREEN.

### ADR-5: Realtime scoping

**Choice**:

- `useRealtime` (account-wide channel `inbox-realtime`): `messages` with `event: 'INSERT'` only, plus `conversations` with `event: '*'` (unchanged).
- New `useThreadRealtime(conversationId, onUpdate)` in `src/hooks/use-thread-realtime.ts`: channel `thread:<conversationId>`, `postgres_changes` `{ event: 'UPDATE', schema: 'public', table: 'messages', filter: 'conversation_id=eq.<conversationId>' }`. The channel is torn down on conversation change and unmount, the same way as the existing `reactions:<id>` channel.
- Row-patch contract (`src/lib/inbox/patch-by-id.ts`): `patchById<T extends {id:string}>(list: T[], id: string, patch: Partial<T>): T[]` returns **the same array reference** when the id is absent or every patched field is already equal. Otherwise it returns a copy with only that element replaced. It is used for message UPDATE, conversation UPDATE, the INSERT preview patch, and the status, assign and not-business handlers in `inbox/page.tsx`. The day grouping becomes `useMemo` on `displayMessages` (slice 3) and is replaced by `buildThreadItems` (slice 4).

**Deviation and rationale**: the proposal scopes all `messages` changes per conversation. The INSERT stream cannot be scoped without regressing the chat sound and the list preview, which only exist for non-active conversations and read from message INSERTs. The volume problem is UPDATEs: status ladder events for every outbound message, and from slice 6 the media settle updates. Those are now filtered server-side. INSERTs for non-active conversations cost one `patchById` on the list and no thread work.

**Ordering note (accepted)**: splitting INSERT and UPDATE across two channels (`inbox-realtime` and `thread:<id>`) removes any ordering guarantee between them; the browser may deliver an UPDATE for a row before its INSERT, or may never deliver the UPDATE at all if the channel is momentarily down. This is accepted. A dropped UPDATE for a row that is not in the open thread's state yet is self-healing: the INSERT (or the next UPDATE for that row) patches it, and a reconnect or tab-visible resync refetches the newest page and merges by id. No cross-channel sequencing, ack or buffer is added for this; the resync path plus per-row id patches are the recovery. Realtime remains best-effort, as it already was.

**Alternatives**: deriving the sound from `conversations` UPDATE (`unread_count` rising) was rejected as a semantic change to the B1.5 gate without its tests. Broadcast was rejected (out of scope).

### ADR-6: Migration 400, media metadata

`supabase/migrations/400_messages_media_metadata.sql` contains additive, nullable columns. There is no BEGIN/COMMIT, and the header lists the guards. **Re-check the next free number before writing**, using the multi-branch command in `wacrm-migraciones/references/workflow.md`. 397-399 already exist on this branch.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `media_status` | `text` | yes | — | `CHECK (media_status IN ('pending','ready','failed'))`; NULL = legacy / not media |
| `media_path` | `text` | yes | — | object path of the original in `chat-media` |
| `media_thumb_path` | `text` | yes | — | `account-<uuid>/thumbs/<base>.webp` |
| `media_mime` | `text` | yes | — | |
| `media_bytes` | `integer` | yes | — | bucket cap is 16 MiB |
| `media_width` | `integer` | yes | — | original, after EXIF orientation |
| `media_height` | `integer` | yes | — | |
| `media_error` | `text` | yes | — | why `failed`, or why there is no thumbnail (`thumbnail: …`) |
| `media_claimed_at` | `timestamptz` | yes | — | set at insert and on every sweeper claim |
| `media_attempts` | `smallint` | no | `0` | fast default, no table rewrite (PG ≥ 11) |

- Constraint named `messages_media_status_check`, `ADD CONSTRAINT … NOT VALID` then `VALIDATE` in the same file. All existing rows are NULL, so validation is trivial.
- Index: `CREATE INDEX IF NOT EXISTS idx_messages_media_pending ON public.messages (media_claimed_at) WHERE media_status = 'pending';`. It is tiny, and only the sweeper reads it. It is not `CONCURRENTLY`, because the Management API applies the file as one statement batch, and the brief write lock is acceptable at this table size.
- Sweeper support function `public.crm_media_reclamar(p_limit int DEFAULT 5, p_stale interval DEFAULT '5 minutes') RETURNS TABLE (id uuid, conversation_id uuid, message_id text, media_url text, content_type text, content_text text, created_at timestamptz, media_attempts smallint, accion text)`, `LANGUAGE plpgsql SECURITY DEFINER SET search_path = public`. It does two things:
  1. `UPDATE … SET media_status='failed', media_error = CASE …` for pending rows with `media_attempts >= 3` (`'sweeper: attempts exhausted'`) or `created_at < now() - interval '7 days'` (`'meta window expired'`). These rows are returned with `accion = 'fallida'`.
  2. Up to `p_limit` rows `WHERE media_status='pending' AND media_claimed_at < now() - p_stale`, selected `ORDER BY media_claimed_at FOR UPDATE SKIP LOCKED`, are updated with `media_claimed_at = now(), media_attempts = media_attempts + 1` and returned with `accion = 'reintentar'`.

  `REVOKE ALL … FROM PUBLIC, anon, authenticated; GRANT EXECUTE … TO service_role`. This follows the `cerebro_webhook_outbox_reclamar` pattern.
- **text + CHECK, not an enum**: the codebase already uses CHECK lists (`content_type`, `status`). An enum would make the ROLLBACK and any future value harder (`ALTER TYPE … ADD VALUE` cannot run inside a transaction block on older paths), and it buys nothing here.
- `supabase/migrations/ROLLBACK-400-messages-media-metadata.sql`: `DROP FUNCTION IF EXISTS public.crm_media_reclamar(int, interval); DROP INDEX IF EXISTS idx_messages_media_pending; ALTER TABLE public.messages DROP CONSTRAINT IF EXISTS messages_media_status_check, DROP COLUMN IF EXISTS …` for all ten columns.
- Assertion `supabase/staging/assertions/messages-media-metadata.sql`. It starts with `\set ON_ERROR_STOP on`, builds `pg_temp` fixtures (account, contact, conversation) and ends `RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'`. Cases:
  1. A legacy-shape insert (no new columns) gets `media_status IS NULL` and `media_attempts = 0`.
  2. `media_status = 'bogus'` is rejected.
  3. A pending row claimed 10 minutes ago is returned as `reintentar` with attempts +1.
  4. A pending row claimed 1 minute ago is not returned.
  5. A pending row with attempts = 3 becomes `failed` and is returned as `fallida`.
  6. A pending row older than 7 days becomes `failed`, with error `meta window expired`.
  7. `ready` and NULL rows are never touched.
  8. `has_function_privilege('authenticated', …, 'EXECUTE')` is false.
- Cycle: `staging-migracion.sh aplicar` with no function list (none redefined), then `relacionadas 400_messages_media_metadata.sql media_url` (must show no new DIFF, a success criterion), then `previa`, the owner's go-ahead, `aplicar`, and `verificar`.

### ADR-7: Ingest decoupling

Exact order inside `processMessage` for `image | video | document | audio | sticker`, all within the existing `after()`:

1. Contact, conversation and `conversation.created` (unchanged). Reactions short-circuit (unchanged).
2. `parseMessageContent` **no longer downloads**. It returns `mediaRef: { mediaId, mime } | null`, and `mediaUrl = '/api/whatsapp/media/<mediaId>'` as the placeholder.
3. Reply context, `contentType` mapping, and the `isFirstInboundMessage` count (unchanged).
4. **Dedupe guard (new)**: `messages.select('id').eq('conversation_id', conv).eq('message_id', wamid).eq('sender_type','customer').limit(1)`. If a row exists, return `{ guardado: true }` without inserting, settling or dispatching, and log `[webhook] duplicate wamid skipped`. It uses `idx_messages_message_id`. It is not race-proof against two concurrent deliveries of the same wamid; see open questions.
5. INSERT with `media_status: 'pending'`, `media_url: <proxy>`, `media_mime: mime`, `media_claimed_at: now`, `media_attempts: 1`, then `.select('id').single()`. **This is the panel-visible point**: realtime INSERT reaches every member.
6. Conversation UPDATE (preview and unread), the first-inbound invite callback, and `flagBroadcastReplyIfAny` (unchanged position relative to the insert).
7. `settleInboundMedia({ messageRowId, mediaRef, accessToken, accountId })` in the new `src/lib/whatsapp/inbound-media.ts`:
   - `getMediaUrl` (10 s `AbortSignal.timeout`), then `downloadMedia` (25 s), the 16 MiB check, Storage upload of the original at today's path `account-<id>/<ms>-wa-<mediaId>.<ext>` (20 s), and for images and stickers `makeThumbnail` (`src/lib/storage/media-thumbnail.ts`, dynamic `import('sharp')`) plus the thumbnail upload with `upsert: true`.
   - One retry with a 1 s backoff on Meta or Storage network errors. **Bound**: about 2 × 55 s worst case per media message. `maxDuration = 60` is a Vercel-style ceiling and is not enforced by `next start`, so the timeouts are the real bound.
   - Success: `UPDATE messages SET media_url=<public-shape URL as today>, media_path, media_thumb_path, media_mime, media_bytes, media_width, media_height, media_status='ready', media_error=<thumbnail error or null> WHERE id=$id AND media_status='pending'`.
   - A thumbnail failure never fails the media: status `ready`, no thumbnail, and the reason goes in `media_error`.
   - **Failure path**: any error after the retry, or the size cap, runs `UPDATE … SET media_status='failed', media_error=<message> WHERE id=$id AND media_status='pending'`. `media_url` **stays `/api/whatsapp/media/<mediaId>`**, byte-identical to today's fallback value.
   - The `AND media_status='pending'` guard makes the settle idempotent against a concurrent sweeper.
8. **Bot-facing tail**, extracted unchanged in content and order into `runInboundTail(args)` in `src/lib/whatsapp/inbound-tail.ts`: `dispatchInboundToFlows`, then `runAutomationsForTrigger` (fire-and-forget as today), then `dispatchInboundToAiReply`, then `dispatchEventDurably('message.received')`. It runs strictly after step 7 resolves. Non-media messages call it directly after step 6, which is their current order.

`processMessage` returns `{ guardado: true }` after the tail, so `whatsapp_webhook_log.procesado` still means "stored and dispatched", and the ingest watchdog (migration 300) keeps its meaning.

**Sweeper** (`src/lib/whatsapp/media-sweeper.ts`, `sweepPendingMedia(db, { limit: 5, budgetMs: 25_000 })`):
- It is called by the existing `/api/cron/webhook-outbox` worker **after** `flushWebhookOutbox`, so durable events never wait on media. That worker is triggered every minute by pg_cron with the shared secret. No new cron job, route or secret is added.
- It calls `rpc('crm_media_reclamar', { p_limit: 5 })`.
- For `reintentar` rows, it parses the media id from `media_url` (`/api/whatsapp/media/<id>`), resolves the account token through `conversations.account_id` and `whatsapp_config`, and runs `settleInboundMedia`. For `fallida` rows there is nothing to settle.
- For both classes, it runs `runInboundTail` **only if `created_at > now() - 24 h`**: a late answer outside the customer window is worse than none. The tail arguments are rebuilt as follows: `contactId` from the conversation, `configOwnerUserId` from `whatsapp_config.user_id`, `isFirstInboundMessage` = no earlier customer message in the conversation, `contactWasCreated: false`, `interactiveReplyId: null` (media is never interactive). The group invite is not replayed.
- It stops when the budget is spent. The worker's JSON gains a `media: { retried, settledReady, settledFailed, dispatched, skippedStale }` field.
- Cadence: every minute (the existing job), claiming rows stale for 5 minutes or more and making at most 3 attempts, so a row settles within about 20 minutes worst case.

**Alternatives**: a separate cron route and pg_cron job (rejected: a new SQL schedule plus a new route that would 404 until slice 6b, for no isolation benefit at 5 rows per minute); dispatching before settle (rejected: the Cerebro reads deposit receipt images); leaving in-request failures `pending` for the sweeper (rejected: it delays the bot by 5 or more minutes on a plain Meta error, where today's behaviour falls back at once).

### ADR-8: Bot event ordering proof

In `src/app/api/whatsapp/webhook/route.test.ts`, which already has a fake Supabase builder that records `inserts` and `updates` per table, add an ordered global `calls` log. The `messages` update fake appends `{ kind: 'messages.update', payload }`. The mocks of `dispatchInboundToFlows`, `runAutomationsForTrigger`, `dispatchInboundToAiReply` and `dispatchEventDurably` append `{ kind: <name>, event }`. `getMediaUrl` and `downloadMedia` are mocked through `vi.mock('@/lib/whatsapp/meta-api')`, and Storage and `sharp` through `vi.mock('@/lib/storage/media-thumbnail')` plus a fake `storage.from().upload`.

Tests:
1. **image, success**: the `messages` insert payload has `media_status: 'pending'` and `media_url: '/api/whatsapp/media/<id>'`. The index of the first update with `media_status: 'ready'` is lower than the index of every bot-facing call, and `message.received` is called exactly once.
2. **image, Meta download throws twice**: an update with `media_status: 'failed'` comes before every bot-facing call, and no update ever changes `media_url`.
3. **invariant over every media type** (`image, video, document, audio, sticker`, parameterised): at the moment each bot-facing mock is invoked, the fake's latest `messages` state for that row has `media_status ∈ {ready, failed}`. The mock reads the builder's recorded state when it is invoked, so the test checks the state the event actually observed, not only the call order.
4. **text**: no `media_status` in the insert, and the tail runs (regression).
5. **duplicate wamid**: a second delivery inserts nothing and dispatches nothing.

The sweeper test `src/lib/whatsapp/media-sweeper.test.ts` asserts the same invariant for `reintentar` and `fallida` rows, and that no tail runs for rows older than 24 h. The staging check, per `wacrm-probar-staging`, uses a PRUEBA image to confirm the row shows `pending` and then `ready` in the panel, with `ai_autoreply_disabled`. The staging Cerebro workflow is never executed.

### ADR-9: Backfill

- Core: `src/lib/storage/media-backfill.ts`. Only relative imports and injected `db` and `storage`, so vitest can test it without network: `planBatch`, `processRow`, `summarise`. Runner: `infra/media/backfill-media.mts`, run with `node --experimental-strip-types` (verify the host Node version ≥ 22.6). It reads `NEXT_PUBLIC_SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` from an env file given by `--env <file>`, and never prints them.
- Selection (keyset, which makes it resumable): `media_url` is a chat-media URL and `media_status IS NULL`. Pending rows are never the backfill's job: they carry the legacy proxy URL, and only the sweeper can settle them. Ordered `(created_at, id)`, `--batch 25`, with `--sleep-ms 500` between batches and an optional `--limit`. Processed rows leave the selection, so a rerun resumes by construction. No checkpoint file is needed, and `--after <created_at>,<id>` only skips ahead.
- Per account prefix, one paged `storage.list` gives `size` and `mimetype` for every object (one call per 1,000 objects). Only images and stickers are **downloaded** to make thumbnails, so audio, video and document bytes are never read.
- Per row:
  - Object found, image: thumbnail uploaded with `upsert: true` (deterministic name), then `media_status='ready'` and all fields set.
  - Object found, other type: `ready` with path, mime and bytes only.
  - Object missing: `failed`, `media_error='backfill: object missing'`.
  - `sharp` fails: `ready`, `media_error='thumbnail: <reason>'`.
- Rows whose `media_url` is legacy `/api/whatsapp/media/` are counted and left untouched (`legacy_meta`). Their Meta ids are long expired.
- `--dry-run` performs the same selection and listing, writes nothing and prints `would_ready_with_thumb`, `would_ready_no_thumb`, `would_fail_missing` and `legacy_meta` per content type. The real run prints the same counters, which makes the "dry-run and real counts match" criterion checkable.
- Order: staging dry run, staging real run, production dry run, then the production real run in the owner-approved window (open decision 1).
- **Storage growth**: about 3,600 images × 12-20 kB (360 px WebP at q65) ≈ **45-72 MB**. The proposal's 70-110 MB figure assumed larger thumbnails. Reads: images only, well under the proposal's 875 MB total.

### ADR-10: The 1.9 s pre-fetch window (profile only, no fix designed)

Profiling runs at the **start of slice 1, before any code change**, then again after slices 1 and 4:

1. Add temporary `performance.mark('inbox:select')` in `handleSelectConversation` and `performance.mark('inbox:thread-fetch')` immediately before the page fetch, behind a `?perf=1` query flag. These marks are removed before merge.
2. Record a Chrome DevTools Performance trace for the baseline method: fresh session, heaviest conversation.
3. Read the gap between the two marks. Classify it as long tasks (render, commit) or idle awaiting.

Hypotheses to confirm or reject, with what would show it:
- (a) supabase-js auth initialisation or lock wait before the first PostgREST call. This shows as idle time with `_acquireLock`/`getSession` frames, and is checked on staging with `auth.debug`. Slice 1 removes the client PostgREST call from the open path, so slice 1 alone may remove this cause.
- (b) render and commit cost of the list, thread and composer on selection: long tasks in the flame chart.
- (c) chunk loading of thread code: network waterfall.
- (d) effects queued behind other effects (profiles, reactions, presence).

If the cause lies outside the inbox (layout, auth bundle), it is reported and not fixed here (proposal risk). Any fix is a separate slice 4b, sized after the trace, and its own design note is appended to this file.

## Data Flow

Thread open (slices 1-2):

    click -> MessageThread effect -> GET /api/inbox/messages?conversationId=..
               |                         | requireRole(viewer) [cookie session]
               |                         | Promise.all(conv-in-account, page DESC limit+1)  (RLS)
               |                         | signChatMediaUrls(media_url[] + thumb[]) -> createSignedUrls x1
               |  <- { messages ASC, hasMore, nextCursor, signed, expiresIn }
               +-> seedSignedMedia(signed) -> onMessagesLoaded(rows)
                     -> ThreadRow/MessageBubble -> peekSignedMediaSrc -> <img loading=lazy src=signed>
                                                                      -> Supabase Storage (Range, once)

Inbound media (slices 5b-6b):

    Meta POST -> verify HMAC -> 200 ack
       after(): log row -> config -> contact/conv -> dedupe guard
                -> INSERT messages(pending, media_url=/api/whatsapp/media/<id>)  --realtime INSERT--> panel (placeholder)
                -> conv UPDATE (preview/unread)                                  --realtime-->       list
                -> settleInboundMedia: Meta url -> download -> upload -> sharp thumb -> upload
                -> UPDATE messages(ready|failed)                                 --filtered UPDATE--> open thread
                -> runInboundTail: flows -> automations -> AI reply -> message.received (durable)
       pg_cron 1/min -> /api/cron/webhook-outbox -> flush outbox -> sweepPendingMedia
                -> crm_media_reclamar -> settle -> (age < 24 h) runInboundTail

Realtime (slice 3):

    channel inbox-realtime : messages INSERT (sound, preview, append if active) + conversations *
    channel thread:<id>    : messages UPDATE filter conversation_id=eq.<id> -> patchById(messages)
    channel reactions:<id> : unchanged

## File Changes

| Slice | File | Action | Description |
|---|---|---|---|
| 1 | `src/lib/storage/chat-media-server.ts` | Modify | add `signChatMediaUrls(urls, accountId, ttl)`, extracted from the sign route |
| 1 | `src/app/api/chat-media/sign/route.ts` | Modify | delegate to the helper; contract unchanged |
| 1 | `src/app/api/inbox/messages/route.ts` | Create | thread page plus signed map (ADR-1) |
| 1 | `src/lib/inbox/thread-page.ts` | Create | cursor validation regexes, response types, `fetchThreadPage(conversationId, cursor?)` client helper |
| 1 | `src/lib/storage/signed-media.ts` | Modify | `seedSignedMedia`, `peekSignedMediaSrc`, `invalidateSignedMedia` |
| 1 | `src/lib/storage/use-media-src.ts` | Modify | synchronous first value from the peek |
| 1 | `src/components/inbox/message-thread.tsx` | Modify | first page and older pages via `fetchThreadPage`, seed before load |
| 2 | `src/components/inbox/message-bubble.tsx` | Modify | signed-first, no proxy first source, `preload="none"`, lazy images, reserved box, error re-sign once, `React.memo` |
| 2 | `src/components/inbox/thread-row.tsx` | Create | memoized row with stable id-based callbacks |
| 2 | `src/components/inbox/message-thread.tsx` | Modify | stable callbacks, render `ThreadRow` |
| 3 | `src/lib/inbox/patch-by-id.ts` | Create | identity-preserving row patch |
| 3 | `src/hooks/use-realtime.ts` | Modify | `messages` INSERT only |
| 3 | `src/hooks/use-thread-realtime.ts` | Create | filtered UPDATE channel |
| 3 | `src/app/(dashboard)/inbox/page.tsx` | Modify | `patchById` everywhere, wire `useThreadRealtime` |
| 3 | `src/components/inbox/message-thread.tsx` | Modify | `useMemo` grouping |
| 4 | `package.json` | Modify | `react-virtuoso` |
| 4 | `src/lib/inbox/thread-items.ts` | Create | items, separators below, `nextFirstItemIndex`, `indexOfMessage` |
| 4 | `src/components/inbox/message-thread.tsx` | Modify | `Virtuoso`, header, overlay, jump by index, `highlightId`, resync keeps history |
| 4b | (decided after the trace) | — | pre-fetch fix, if any is in scope |
| 5a | `supabase/migrations/400_messages_media_metadata.sql` | Create | columns, check, index, `crm_media_reclamar` |
| 5a | `supabase/migrations/ROLLBACK-400-messages-media-metadata.sql` | Create | drops |
| 5a | `supabase/staging/assertions/messages-media-metadata.sql` | Create | self-reverting assertion |
| 5b | `package.json` | Modify | `sharp` explicit |
| 5b | `src/lib/storage/media-thumbnail.ts` | Create | `thumbnailPathFor`, `makeThumbnail` (dynamic sharp import) |
| 5b | `src/app/api/whatsapp/webhook/route.ts` | Modify | `persistMedia` also writes metadata, thumbnail, `ready` (order unchanged in 5b) |
| 5b | `src/types/index.ts` | Modify | optional `media_*` fields on `Message` |
| 5b | `src/app/api/inbox/messages/route.ts` | Modify | also sign thumbnail proxy URLs |
| 5b | `src/components/inbox/message-bubble.tsx` | Modify | thumbnail first, width/height, pending and failed copy |
| 5b | `messages/es.json`, `messages/en.json` | Modify | `Inbox.bubble.mediaPending`, `mediaFailed` |
| 6a | `src/lib/whatsapp/meta-api.ts` | Modify | optional `signal` on `getMediaUrl` and `downloadMedia` |
| 6a | `src/lib/whatsapp/inbound-media.ts` | Create | `settleInboundMedia` |
| 6a | `src/lib/whatsapp/inbound-tail.ts` | Create | `runInboundTail`, extracted verbatim |
| 6a | `src/app/api/whatsapp/webhook/route.ts` | Modify | insert-first order, dedupe guard, call settle then tail |
| 6b | `src/lib/whatsapp/media-sweeper.ts` | Create | `sweepPendingMedia` |
| 6b | `src/app/api/cron/webhook-outbox/route.ts` | Modify | call the sweeper after the flush |
| 7 | `src/lib/storage/media-backfill.ts` | Create | backfill core |
| 7 | `infra/media/backfill-media.mts` | Create | CLI runner (`--dry-run`, `--batch`, `--sleep-ms`, `--limit`, `--after`, `--env`) |

Unchanged by design: `src/app/api/chat-media/[...path]/route.ts`, `src/app/api/whatsapp/media/[mediaId]/route.ts`, and every SQL function that reads `messages.media_url`.

## Interfaces / Contracts

```ts
// src/lib/inbox/thread-page.ts
export interface ThreadCursor { createdAt: string; id: string } // raw created_at string, never re-formatted
export interface ThreadPageResponse {
  messages: Message[];            // chronological ascending
  hasMore: boolean;               // from limit + 1
  nextCursor: ThreadCursor | null; // oldest row of this page when hasMore
  signed: Record<string, string>; // key = stored media_url, or chatMediaProxyUrl(thumb path)
  expiresIn: number;              // seconds, 3600
}
export function fetchThreadPage(conversationId: string, cursor?: ThreadCursor, limit?: number): Promise<ThreadPageResponse>;

// src/lib/storage/chat-media-server.ts
export function signChatMediaUrls(urls: string[], accountId: string, ttlSeconds?: number):
  Promise<{ signed: Record<string, string>; expiresIn: number; ok: boolean }>;

// src/lib/storage/signed-media.ts
export function seedSignedMedia(signed: Record<string, string>, expiresInSeconds: number, receivedAt?: number): void;
export function peekSignedMediaSrc(url: string | null | undefined): string | null;
export function invalidateSignedMedia(url: string): void;

// src/lib/inbox/patch-by-id.ts
export function patchById<T extends { id: string }>(list: T[], id: string, patch: Partial<T>): T[];

// src/lib/inbox/thread-items.ts
export interface ThreadItem { id: string; message: Message; separatorBelow: string | null } // ISO day of next message
export function buildThreadItems(messages: Message[]): { items: ThreadItem[]; headerDay: string | null };
export function nextFirstItemIndex(prev: number, prependedCount: number): number;
export function indexOfMessage(items: ThreadItem[], id: string, firstItemIndex: number): number | null;

// src/lib/storage/media-thumbnail.ts
export function thumbnailPathFor(originalPath: string): string; // account-x/thumbs/<base>.webp
export function makeThumbnail(bytes: Buffer, mime: string):
  Promise<{ thumb: Buffer; width: number; height: number } | { error: string } | null>; // null = not an image

// src/lib/whatsapp/inbound-media.ts
export type MediaSettlement =
  | { status: 'ready'; mediaUrl: string; path: string; thumbPath: string | null; mime: string; bytes: number; width: number | null; height: number | null; error: string | null }
  | { status: 'failed'; error: string };
export function settleInboundMedia(args: { db: SupabaseClient; messageRowId: string; mediaId: string; mime: string; accessToken: string; accountId: string }): Promise<MediaSettlement>;

// src/lib/whatsapp/inbound-tail.ts
export function runInboundTail(args: {
  db: SupabaseClient; accountId: string; configOwnerUserId: string; contactId: string; conversationId: string;
  wamid: string; contentType: string; contentText: string | null; interactiveReplyId: string | null;
  isFirstInboundMessage: boolean; contactWasCreated: boolean; rawTextBody?: string;
}): Promise<void>;

// src/types/index.ts (Message additions, all optional)
media_status?: 'pending' | 'ready' | 'failed' | null;
media_path?: string | null; media_thumb_path?: string | null; media_mime?: string | null;
media_bytes?: number | null; media_width?: number | null; media_height?: number | null; media_error?: string | null;
```

## Testing Strategy

Strict TDD: every slice starts with RED tests in the files listed below.

| Slice | Test file | What it proves |
|---|---|---|
| 1 | `src/app/api/inbox/messages/route.test.ts` (new) | 401/403 passthrough; 400 cases (bad uuid, one cursor field, cursor with `,` or `)`, limit 0/101); 404 for a conversation of another account; keyset `.or()` string built from the raw cursor; `limit+1` sets `hasMore`; ascending order; `signed` excludes foreign-account and non-chat-media URLs; signing error gives 200 with `signed: {}`; `Cache-Control: private, no-store` |
| 1 | `src/lib/storage/chat-media-server.test.ts` (extend) | `signChatMediaUrls` skips foreign paths, dedupes paths, maps duplicates of one path to every original key |
| 1 | `src/app/api/chat-media/sign/route.test.ts` (keep green) | contract unchanged after the extraction |
| 1 | `src/lib/storage/signed-media.test.ts` (extend) | seed then peek is fresh; inside the 5-min margin peek is null and resolve re-signs; invalidate forces re-sign |
| 1 | `src/lib/inbox/thread-page.test.ts` (new) | cursor regexes accept PostgREST timestamps with microseconds and offsets, and reject injection strings |
| 2 | `src/components/inbox/message-bubble.test.tsx` (extend) | seeded image renders signed src on the first render; video/audio/document never render a `/api/chat-media/` src before resolution; `preload="none"`; `loading="lazy"` plus the reserved box; error re-signs once, then falls back; legacy Meta URL unchanged |
| 2 | `src/components/inbox/thread-row.test.tsx` (new) | React `Profiler` counts: re-rendering the parent with equal props does not re-render the row; a changed message re-renders only that row |
| 3 | `src/lib/inbox/patch-by-id.test.ts` (new) | same reference when the id is absent or the patch is equal; single-element replacement otherwise |
| 3 | `src/hooks/use-realtime.test.ts` (new) | `messages` subscribed with `event: 'INSERT'` only; `conversations` with `'*'` |
| 3 | `src/hooks/use-thread-realtime.test.ts` (new) | filter `conversation_id=eq.<id>`, `event: 'UPDATE'`; channel removed on id change and unmount |
| 4 | `src/lib/inbox/thread-items.test.ts` (new) | separators below at day boundaries; prepending N same-day or other-day messages leaves existing items deep-equal; `nextFirstItemIndex`; `indexOfMessage` in the verified index space |
| 5a | `supabase/staging/assertions/messages-media-metadata.sql` | ADR-6 cases 1-8 |
| 5b | `src/lib/storage/media-thumbnail.test.ts` (new) | path convention, rejects unsafe paths, real `sharp` on a tiny PNG fixture gives WebP with longest side ≤ 360 and the original dimensions, non-image gives null, corrupt bytes give `{ error }` |
| 5b | `src/app/api/whatsapp/webhook/route.test.ts` (extend) | persisted image writes `media_*` and `ready`; a thumbnail failure still gives `ready` with `media_error` |
| 5b | `src/components/inbox/message-bubble.test.tsx` (extend) | thumbnail src preferred, width/height attributes, original resolved only on zoom; pending and failed copy |
| 6a | `src/app/api/whatsapp/webhook/route.test.ts` (extend) | ADR-8 tests 1-5 |
| 6a | `src/lib/whatsapp/inbound-media.test.ts` (new) | timeouts abort, one retry, size cap gives failed, `WHERE media_status='pending'` guard applied |
| 6b | `src/lib/whatsapp/media-sweeper.test.ts` (new) | `reintentar` settles before tail; `fallida` runs tail only; age ≥ 24 h settles without tail; budget stops the loop |
| 6b | `src/app/api/cron/webhook-outbox/route.test.ts` (new or extend) | sweeper called after flush; unauthorized secret runs neither |
| 7 | `src/lib/storage/media-backfill.test.ts` (new) | selection keyset resumes; dry run writes nothing and counts equal the real run on the same fixture; missing object gives failed; legacy Meta URLs untouched; non-images never downloaded |

E2E and manual checks, staging first per `wacrm-probar-staging`: a long PRUEBA thread checks open-at-bottom, older-page anchor, jump to a quote and the resync position; a PRUEBA inbound image checks the pending and then ready transition. Measurement on staging and production after slices 1, 2, 4 and 5b+7 with the baseline method, recorded in this change.

## Threat Matrix

N/A: the change has no shell, subprocess, VCS/PR automation, executable-file classification or agent-routing boundary. The backfill runner is a one-off CLI with no shell composition. The applicable security boundary is HTTP access control, covered by ADR-1 (session plus account check, the RLS client, an unchanged signing gate, foreign-path tests and cursor injection validation) and by the unchanged private bucket.

## Migration / Rollout

- Slices 1, 2, 3, 4 and 4b are panel-only. Each ships with `wacrm-publicar-panel` and rolls back by redeploying. **Slices 1 and 2 read no new column**: the route uses `select('*')` and ignores unknown fields, the signed map keys on `media_url`, and the bubbles branch on `media_status` and `media_thumb_path` only from 5b on.
- 5a: migration 400 goes through the staging cycle, then `previa`, the owner's go-ahead, `aplicar` and `verificar`. It ships before any build that writes or reads the columns. It has no app dependency on its own.
- 5b: needs 400 applied in production. Verify that `sharp` loads in the standalone build on the production host before deploying. Thumbnail failure degrades to no thumbnail.
- 6a: the webhook order change. Rollback is a redeploy. Rows left `pending` are completed by the 6b sweeper while it stays deployed. A 6a rollback must keep 6b deployed or run one manual call of the sweeper. Otherwise `crm_media_reclamar` marks them `failed` once their attempts or 7 days run out, and their `media_url` stays the working legacy proxy URL.
- 6b: no SQL (it uses 400's function). It can ship together with 6a or right after it.
- 7: staging dry run and real run, then production dry run and the real run in the approved window.
- Rollback order for the schema: panel first, then `ROLLBACK-400` (owner approval only).

### Slice budget (auto-chain, 400 authored lines)

| Slice | Est. lines | Schema |
|---|---|---|
| 1 server read + seeding | 350-400 | No |
| 2 bubbles + memo row | 250-330 | No |
| 3 realtime split + patch | 200-280 | No |
| 4 virtualization | 330-400 | No |
| 4b pre-fetch fix | unknown (after trace) | No |
| 5a migration 400 | 220-300 (SQL) | Yes |
| 5b thumbnails at ingest + readers | 300-380 | uses 400 |
| 6a insert-first + tail extraction + ordering tests | 330-400 | uses 400 |
| 6b sweeper | 180-250 | uses 400 |
| 7 backfill | 250-330 | uses 400 |

Splits relative to the proposal: 5 became 5a and 5b, 6 became 6a and 6b, and 4b was added. Each original slice would exceed 400 lines.

## Decision to Slice Map

| Decision | Slice(s) |
|---|---|
| ADR-1 server thread read route | 1 (thumbnail signing added in 5b) |
| ADR-2 signed URL seeding and refresh | 1 (seed and peek), 2 (error re-sign) |
| ADR-3 media rendering, proxy fallback, memo | 2 (signed-first, lazy, preload, memo), 5b (thumbnails, dimensions, pending and failed) |
| ADR-4 virtualization with react-virtuoso | 4 |
| ADR-5 realtime scoping and row patch | 3 |
| ADR-6 migration 400 | 5a |
| ADR-7 ingest decoupling and sweeper | 6a (order, dedupe, settle, tail), 6b (sweeper) |
| ADR-8 bot ordering proof | 6a (webhook), 6b (sweeper) |
| ADR-9 backfill | 7 |
| ADR-10 pre-fetch profiling | trace before 1, re-trace after 1 and 4; fix, if any, in 4b |

## Deviations from the proposal

1. Realtime: message INSERTs stay account-wide; only UPDATEs are filtered (ADR-5).
2. Dedupe did not exist; this design adds a pre-insert guard (ADR-7 step 4).
3. Pending rows carry the legacy proxy URL in `media_url`, not NULL, so every existing reader keeps a working value (ADR-7 step 5).
4. Thumbnail estimate lowered to 45-72 MB through a 360 px / q65 encoding (ADR-9).
5. Slices 4, 5 and 6 are split to respect the 400-line budget.

## Open Questions

- [ ] **Storage quota**: about 875 MB already stored plus 45-72 MB of thumbnails approaches the Free plan's 1 GB file-storage limit. Check the current usage in the dashboard before slice 7. This could block the backfill in production.
- [ ] A dedupe guard without a unique index is not safe against concurrent duplicate deliveries. Should a later change clean up historical duplicates and add `UNIQUE (conversation_id, message_id) WHERE sender_type='customer'`? Out of scope here.
- [ ] Audio `preload="none"` hides voice-note duration until play. Is `metadata` for audio only acceptable for the bytes budget?
- [ ] Should `followOutput` keep today's always-follow behaviour, or follow only when at the bottom or after one's own send? This design keeps parity.
- [ ] Owner decisions 1-3 from the proposal (backfill window, Spanish copy for pending and failed, slice order) remain open.
- [ ] Verify at implementation: `react-virtuoso`'s React 19.2 peer range and its `scrollToIndex` index space with `firstItemIndex`; Node ≥ 22.6 on the host for `--experimental-strip-types`; `sharp` in the standalone trace.
