# Proposal: Inbox thread and WhatsApp media performance

## Intent

Opening a heavy conversation in the inbox is slow, and most of the delay comes from how media reaches the browser, not from the database. Production baseline (2026-11-27, fresh session, heaviest conversation, 1,100 messages):

| Step | Time after click | Notes |
|------|------------------|-------|
| `messages` query starts | 1,920 ms | 1.9 s of client work before the fetch; query itself 463 ms |
| 29 byte-proxy requests `/api/chat-media/account/...` | 2,520 ms | 494-3,023 ms each |
| `/api/chat-media/sign` starts | 2,587 ms | takes 2,962 ms |
| first signed Storage URL starts (37 total) | 5,610 ms | |

- Payload: the last 50 messages carry 50 media objects, 5,314 kB (avg 106 kB, max 818 kB).
- The database is not the bottleneck: the thread page query takes 1.59 ms and the conversation list 0.47 ms.

Root causes, verified in code:
1. **Client-side read chain.** The thread is queried from the browser (`message-thread.tsx:300-331`), then the media URLs are signed in a second round-trip (`signed-media.ts:37-108`). Images cannot start until signing returns (`use-media-src.ts:24-32`).
2. **Byte proxy as a first source.** Audio, video and documents start on `/api/chat-media/...` (`message-bubble.tsx:207-208, 227, 240`) and then switch to the signed URL, so each item is downloaded twice. The proxy buffers the whole object even for Range requests (`chat-media-server.ts:28-35`, `api/chat-media/[...path]/route.ts:62-80`). The 29 parallel proxy downloads also compete with the sign request on the same server; this likely explains part of the 2.9 s sign time, but it is not yet proven.
3. **Ingest blocks delivery.** The webhook awaits the Meta download and Storage upload (`webhook/route.ts:801`, `persistMedia` at `:1044-1080`) before the `messages` INSERT (`:854`). A media message only appears after its file is stored.
4. **Account-wide, unmemoized realtime.** `use-realtime.ts:47-70` subscribes to every `messages` and `conversations` change with no filter. `inbox/page.tsx:278-281` maps the whole array on each UPDATE, `message-thread.tsx:977` recomputes groups, and `message-bubble.tsx` has no `React.memo`.
5. **No virtualization and full-size images.** 50 messages mount at once. Each image is a plain `<img>` with no `loading`, `width` or `height` (`message-bubble.tsx:142-149`), at full original size (png avg 346 kB).

Success: an agent opens a heavy conversation and sees media start in under 1.5 s. The first page moves less than 1.5 MB, each media item is downloaded once, and a new media message appears in the thread before its file has finished downloading. The private-bucket access model stays exactly as strict as today.

## Scope

### In Scope
- **Server thread read.** A panel route returns one message page (cursor pagination, newest first) together with batched signed URLs for the app's own `chat-media` paths. The client renders from that response, so the separate `/api/chat-media/sign` round-trip disappears from first paint.
  - Membership is checked with the caller's session, the same rule as today's sign route. Objects of another account are never signed. The TTL stays at today's 3,600 s.
  - The client signing module remains as a refresh path for URLs that are near expiry and for media that arrives later through realtime.
- **Direct signed delivery.** Images, audio, video and documents in `chat-media` play and download straight from the signed Storage URL, which supports Range natively.
  - The byte proxy is no longer a first source for them. It stays only as the fallback when signing fails.
  - Legacy Meta media `/api/whatsapp/media/<mediaId>` keeps working unchanged for messages that were already delivered.
  - Audio and video use `preload="none"` or `preload="metadata"`, so their bytes are only transferred on play.
- **Media metadata.** New nullable columns on `messages`, added without changing existing ones: storage path, thumbnail path, mime, byte size, width, height, and media status (`pending | ready | failed`).
  - `media_url` stays the compatibility field. More than 40 source files and several SQL functions (receipts, ID photo, Cerebro) read it, and none of them change.
- **Thumbnails at ingest.** Images and stickers get a sibling thumbnail object generated with `sharp`, stored in the same private bucket under the same account prefix.
  - The thread renders the thumbnail with explicit `width`/`height` and `loading="lazy"`. The full object loads only on open.
  - `sharp` becomes an explicit dependency; today it is only present as a transitive dependency of Next.
- **History backfill.** A one-off, resumable, batched script fills the metadata and thumbnails for the retained history only: objects younger than the 90-day retention window (about 5,000 objects instead of 6,841). It is idempotent per object, has a dry-run mode, and runs on staging before production.
- **Storage retention (90 days).** `chat-media` grows about 200 MB per month and the project is on the free plan's 1 GB ceiling (875 MB stored on 2026-11-27). A recurring job deletes objects older than 90 days, together with their thumbnails, so steady state stays around 650 MB.
  - It runs inside the existing cron worker, batched and rate-limited, with a dry-run mode and a per-run deletion cap.
  - Deletion is by object age, never by conversation. Rows keep `media_url`; the panel already renders a missing object through the existing fallback path, and the thread shows the media as unavailable instead of a broken element.
  - Retention is a product decision recorded here: conversations older than 90 days lose their media files. The message text is never deleted.
- **Decoupled ingest.**
  - The webhook inserts the media message first, with status `pending`, so the panel sees it through realtime at once.
  - It then downloads from Meta, uploads, generates the thumbnail and updates the row to `ready` or `failed`.
  - Pending media that the request lifetime did not finish is retried by a sweeper, inside Meta's 7-day media-id window. Dedupe stays on `messages[].id`.
- **Bot-facing ordering is preserved.** The `message.received` event to the Cerebro, automations, flows and the AI auto-reply are dispatched only after the media is `ready` or `failed`, exactly as today. Only the panel-visible insert moves earlier. This matters because the bot reads deposit receipt images.
- **Scoped realtime.**
  - `messages` changes are subscribed per open conversation with a server-side `conversation_id=eq.<id>` filter.
  - Conversation list updates patch only the affected row by id instead of remapping the whole array.
  - Message bubbles are memoized, and grouping is recomputed only when the message list changes.
- **Virtualized thread.** Only visible messages are mounted (library chosen in design: `react-virtuoso` or `@tanstack/react-virtual`). The virtualized thread keeps scroll-to-bottom, older-page loading at the top and jump-to-message behaviour.
- **Pre-fetch client work.** Profile and remove the work that delays the thread fetch by 1.9 s. The cause is not yet identified; design or apply must profile it before changing code.
- **Measurement.** Re-run the baseline method (same conversation, fresh session, DevTools network timeline) on staging and production after each relevant slice, and record the numbers in the change.

### Out of Scope
- A composite `messages(conversation_id, created_at)` index. It saves about 1 ms and is not the bottleneck.
- Making `chat-media` public, CDN token-less URLs, or any relaxation of the members-only read model from `chat-media-private` (migration 261).
- Supabase Storage image transformations, which need the Pro plan.
- Video posters or frame thumbnails (they need ffmpeg), PDF previews, and audio waveforms.
- Re-encoding or compressing the original objects; originals are kept byte-identical.
- Removing the `/api/chat-media/[...path]` proxy or the `/api/whatsapp/media/<mediaId>` legacy route.
- Making the byte proxy stream Range responses. It is out of the hot path after this change, so this is deferred unless measurements show the fallback is used often.
- Realtime Broadcast migration (recommended by Supabase for scale). Filtered postgres_changes is enough at this volume.
- Changes to the outbound send path, templates, broadcasts, flows editor media, or the v1 API media fields beyond reading the new columns where it is free.
- Conversation list performance (0.47 ms query) beyond the realtime row patch.

## Capabilities

### New Capabilities
- `inbox-thread-read`: server-issued, cursor-paginated thread page that includes signed media URLs for authorised members, with client refresh of near-expiry URLs.
- `chat-media-delivery`: how stored chat media reaches the browser. It covers direct signed URLs with Range, single download per item, lazy thumbnails with known dimensions, play-on-demand audio and video, the proxy as fallback only, and legacy Meta media compatibility, all within the private-bucket access model.
- `media-ingest`: inbound WhatsApp media lifecycle. It covers the message inserted first with `pending` status, asynchronous download, upload and thumbnail, the `ready`/`failed` transition, sweeper retry within the Meta window, dedupe, bot-facing event ordering, and the history backfill.
- `inbox-realtime`: per-conversation message subscriptions, row-level patching of the conversation list, and render memoization and virtualization of the thread.

### Modified Capabilities
- None. (`openspec/specs/` is empty; the prior `chat-media-private` behaviour is preserved and restated as a constraint in `chat-media-delivery`.)

## Approach

The user-visible wins come first and need no schema change. Schema, ingest and backfill follow behind them.

1. **Read path (no schema).** A server route reads the page with the caller's session (RLS stays authoritative), collects the `chat-media` paths it contains and signs them in one `createSignedUrls` call. It returns messages plus a `signed` map. The client renders from that map. This removes the sign round-trip and, together with step 2, the proxy storm that probably slows the sign call.
2. **Bubbles (no schema).** Media elements take the signed URL directly; the proxy is used only on signing failure. Audio and video do not preload. Images get `loading="lazy"` and reserved space, and `React.memo` is added. This step alone should reach zero duplicate downloads.
3. **Realtime and virtualization (no schema).** Use the filtered subscription for the open conversation and id-based row patches. Virtualize the thread and profile the 1.9 s pre-fetch window.
4. **Media model and thumbnails (migration).** Add the additive columns (next free number, currently 400), with ROLLBACK and a self-reverting assertion, per `wacrm-migraciones`. Ingest writes the columns and generates a thumbnail with `sharp`. Readers prefer the thumbnail path when present and fall back to `media_url`.
5. **Decoupled ingest.** Insert with `pending`, process media in the existing `after()` block, update the row, and only then dispatch the bot-facing events. A sweeper (the existing cron worker pattern) retries stale `pending` rows while the Meta media id is still valid; after that, the row goes to `failed` and keeps the legacy proxy URL as today's fallback.
6. **Backfill.** Run a batched, resumable script with the service role: staging first, then production with the owner's go-ahead.

Alternatives considered:
- **A Storage CDN with public thumbnails.** Rejected, because it breaks the members-only model.
- **On-the-fly thumbnails in the proxy.** Rejected, because they cost CPU per view and keep media on the slow path.
- **A long signed-URL TTL to improve browser caching.** Rejected: signed URLs cannot be revoked, so today's TTL is kept.
- **A full rewrite to React Server Components streaming.** Deferred. A server route that returns JSON gives the same round-trip win with less risk in this Next.js version, whose APIs must be checked in `node_modules/next/dist/docs/` during design.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `src/app/api/...` (new thread page route) | New | Message page plus batched signed media map, membership check |
| `src/components/inbox/message-thread.tsx` | Modified | Reads from the server route; virtualized list; grouping memoized |
| `src/components/inbox/message-bubble.tsx` | Modified | Signed-first sources, thumbnails, lazy images with dimensions, no preload, `React.memo` |
| `src/lib/storage/signed-media.ts`, `use-media-src.ts` | Modified | Seeded from the server map; refresh-only role |
| `src/app/api/chat-media/sign/route.ts` | Modified (minor) | Shared signing helper reused by the thread route |
| `src/app/api/chat-media/[...path]/route.ts`, `src/lib/storage/chat-media-server.ts` | Unchanged behaviour | Fallback only |
| `src/app/api/whatsapp/media/[mediaId]/route.ts` | Unchanged | Legacy Meta media |
| `src/app/api/whatsapp/webhook/route.ts` | Modified | Insert-first with `pending`, async media processing, bot events after media settles |
| `src/lib/storage/` (new thumbnail module) | New | `sharp` thumbnail generation and sibling path naming |
| `src/hooks/use-realtime.ts`, `src/app/(dashboard)/inbox/page.tsx` | Modified | Per-conversation filter, id-based row patch |
| `supabase/migrations/400_messages_media_metadata.sql` (+ ROLLBACK, assertion) | New | Additive media columns and status; sweeper support if needed |
| Backfill script (location chosen in design, e.g. `scripts/` or `infra/`) | New | Batched, resumable, dry-run |
| Cron worker (existing durable-event worker pattern) | Modified | Sweep stale `pending` media |
| `package.json` | Modified | `sharp` explicit; virtualization library |
| `src/types/index.ts` | Modified | Message media fields |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Async ingest dispatches `message.received` before the receipt image exists, so the Cerebro reads an empty or proxy `media_url` and mis-verifies a deposit | High if done wrong | Bot-facing dispatch stays after media settles (explicit requirement); test asserts the order; staging check with a PRUEBA receipt (the Cerebro staging workflow is never executed, per `wacrm-probar-staging`) |
| Media stuck in `pending` when the function is frozen after the insert | Med | Sweeper retries within the Meta 7-day window; UI shows a pending state, then `failed` with the legacy proxy fallback |
| Duplicate webhook delivery inserts twice or processes the media twice once the insert moves earlier | Med | Dedupe on `messages[].id` before insert, kept as today; idempotent media update keyed by message id |
| Signed URLs change on every signing, which defeats the browser cache across reloads | Med | In-session cache keyed by path; TTL unchanged; thumbnails make cache misses cheap |
| Server route widens access, for example signing paths of another account | Low | Same `assertChatMediaAccount` gate and membership check as the sign route; tests for foreign paths |
| `sharp` native binary missing or incompatible on the production host | Med | Explicit dependency; build check per `wacrm-publicar-panel`; when thumbnail generation fails, the message is still stored with no thumbnail |
| The backfill loads production Storage (875 MB read) and egress | Med | Batches with throttle, resumable, off-peak window, dry run first; storage growth estimated at about 3,600 thumbnails × ~20-30 kB ≈ 70-110 MB |
| Virtualization breaks scroll anchoring, jump-to-message or older-page loading | Med | Behaviour tests and a browser check on staging with a long PRUEBA thread |
| Filtered realtime misses events the list relied on (unread counts, last message) | Med | Conversation list stays on the account-wide `conversations` subscription; only `messages` is scoped |
| The 1.9 s pre-fetch cause turns out to be outside the inbox (layout, auth, bundle) | Med | Profile first; if the cause is out of scope, report it and keep the criterion measurable |
| New columns diverge from `media_url` for messages written by other paths (outbound sends, v1 API) | Low | Readers fall back to `media_url` when the new columns are null; outbound is out of scope |
| Change exceeds the 400-line review budget | High | Auto-chain slices (forecast below) |

## Review-size forecast

Estimated total: about 2,000-2,600 authored changed lines (additions plus deletions, tests included). This is far above the 400-line budget. Delivery strategy `auto-chain` applies; proposed slices, each independently shippable and reversible:

| # | Slice | Schema | Approx. lines |
|---|-------|--------|---------------|
| 1 | Server thread read and signed media map | No | 350-400 |
| 2 | Signed-first bubbles, lazy images, no preload, memo | No | 250-350 |
| 3 | Scoped realtime and row patch | No | 200-300 |
| 4 | Thread virtualization and pre-fetch profiling fixes | No | 300-400 |
| 5 | Media metadata migration and ingest thumbnails | Yes (400) | 350-400 |
| 6 | Insert-first ingest, sweeper, bot event ordering | No (uses 400) | 300-400 |
| 7 | History backfill script | No | 200-300 |
| 8 | Storage retention job (90 days) and unavailable-media rendering | No | 150-250 |

`sdd-tasks` confirms the exact boundaries. Slices 1-2 are expected to deliver the time-to-first-media and duplicate-download criteria; the bytes criterion depends on slices 2 and 4 (lazy loading), plus 5 and 7 (thumbnails).

## Rollback Plan

- **Panel slices (1-4, and the reader side of 5-7):** redeploy the previous build per `wacrm-publicar-panel`. Slices 1-4 touch no data, so a rollback is a pure redeploy.
- **Migration 400:** `ROLLBACK-400-messages-media-metadata.sql` drops the additive columns and any sweeper support objects. This is safe because `media_url` keeps being written on every path and no reader depends only on the new columns. Production rollback only with the owner's approval. Roll back the panel first, then the migration.
- **Thumbnails and backfill:** thumbnail objects are siblings and never replace originals. Leaving them in place is harmless, and a listed prefix can delete them if needed. The backfill writes only the new columns and the thumbnail objects, so the column drop reverts it.
- **Ingest decoupling (6):** reverting the webhook build restores download-before-insert. Rows left `pending` at revert time are completed by one run of the sweeper or the backfill script, or marked `failed` with the legacy proxy URL.

## Dependencies

- Migration 400 is applied on staging, then on production with the owner's explicit go-ahead, before the panel build that writes or reads the new columns.
- `sharp` must load on the production host; this is verified in the build before slice 5 ships.
- The backfill production run needs the owner's go-ahead and an agreed time window.
- The Next.js 16.4.6 route and `after()` semantics are checked in `node_modules/next/dist/docs/` during design.

## Success Criteria

Measured with the baseline method: fresh session, heaviest production conversation, DevTools network timeline, and the same 50-message page.

- [ ] The first signed media request starts in under 1.5 s after the click (baseline 5.6 s).
- [ ] The heavy conversation's first page transfers under 1.5 MB in total (baseline 5.3 MB of media).
- [ ] Each media item is downloaded at most once per open, with zero byte-proxy requests for `chat-media` objects when signing succeeds (baseline 29).
- [ ] An inbound media message appears in the open thread, as pending, before its file finishes downloading and storing (baseline: after).
- [ ] `message.received` and the other bot-facing dispatches for a media message happen only after its media is `ready` or `failed` (test plus staging check).
- [ ] Legacy `/api/whatsapp/media/<mediaId>` messages still render and play.
- [ ] A non-member and a member of another account get no signed URL and no bytes for foreign objects (tests). The bucket stays private.
- [ ] Media rows stuck in `pending` are retried and settle to `ready` or `failed`.
- [ ] After the backfill, every retained historical image (younger than 90 days) has a thumbnail or a recorded reason why it has none, and the dry-run and real counts match.
- [ ] The retention job deletes only objects older than 90 days, honours the per-run cap, and its dry run reports the same object count as the real run; steady-state `chat-media` stays under 700 MB.
- [ ] A conversation whose media was purged renders the media as unavailable and never as a broken element or an infinite spinner.
- [ ] Migration 400 assertion ends `ALL PASS (rolled back on purpose)`; `relacionadas` shows no new DIFF for functions that read `messages.media_url`.
- [ ] `tsc` is clean and vitest is green, with Strict TDD RED -> GREEN evidence per task.

## Open decisions for the owner (returned to the orchestrator)

1. Backfill in production: approve the run and its window. It reads about 875 MB from Storage and adds an estimated 70-110 MB of thumbnails.
2. Pending media display in the thread: confirm the Spanish UI copy for a media message that is still downloading or has failed ("Descargando archivo…" / "No se pudo descargar el archivo").
3. Slice order: confirm that the no-schema slices (1-4) ship and are measured in production before the migration and ingest slices (5-7).
