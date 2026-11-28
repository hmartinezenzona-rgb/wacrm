# Tasks: Inbox thread and WhatsApp media performance

**Change**: `inbox-media-performance`
**Inputs**: `openspec/changes/inbox-media-performance/proposal.md` (read-only), `openspec/changes/inbox-media-performance/design.md` (read-only), `openspec/changes/inbox-media-performance/specs/inbox-thread-read/spec.md` (read-only), `openspec/changes/inbox-media-performance/specs/chat-media-delivery/spec.md` (read-only), `openspec/changes/inbox-media-performance/specs/media-ingest/spec.md` (read-only), `openspec/changes/inbox-media-performance/specs/inbox-realtime/spec.md` (read-only)
**Delivery**: `auto-chain`, one stacked PR per slice targeting `master`, 400 authored changed lines (`additions + deletions`, tests included) per PR
**Chain strategy**: `stacked-to-main`. Forced by the approved slice order: slices must ship and be measured in production before the next ones, and a tracker-branch chain would hold every slice out of production until the end. Any other strategy is an owner decision, not an apply decision.
**TDD**: Strict TDD enabled. Every behavioural task names its test file and requires observed RED before GREEN. `npx tsc --noEmit` must stay clean at every GREEN. Test runner is vitest (`npm test` = `vitest run`; `vitest.config.ts` includes `src/**/*.test.ts[x]` and `pruebas/**/*.test.ts`).
**Measurement log**: `openspec/changes/inbox-media-performance/measurements.md` (created by the first measurement task; appended by the rest).

## Global rules for every task

- Run everything from the worktree root `/home/onlinefreedom/wacrm-worktrees/mejora-legacy`; never `cd` to the main checkout.
- Never execute the staging Cerebro n8n workflow. Staging fixtures set `ai_autoreply_disabled = true`, per `.claude/skills/wacrm-probar-staging/SKILL.md` (read-only).
- Never paste migration SQL into the conversation; pass file paths, per `.claude/skills/wacrm-migraciones/SKILL.md` (read-only).
- Every migration ships a `ROLLBACK-*.sql` and a self-reverting assertion ending `ALL PASS (rolled back on purpose)`.
- Read the Next.js guides under `node_modules/next/dist/docs/` (read-only) before touching a route handler or `after()`; this Next version differs from training data.
- Threat matrix: `design.md` records **N/A** (no shell, subprocess, VCS/PR automation, executable-file classification or agent-routing boundary). The only security boundary is HTTP access control; its cases are explicit RED tests in T1.2 and T1.3 (cursor injection, foreign-account path, non-member, private bucket).
- Slice reversibility rule: slices 1, 2, 3, 4, 4b, 5b, 6a, 6b and 8 roll back by redeploying the previous panel build per `.claude/skills/wacrm-publicar-panel/SKILL.md` (read-only). Slice 5a rolls back only with `supabase/migrations/ROLLBACK-400-messages-media-metadata.sql` and the owner's approval. Slice 7 reverts by dropping the 400 columns and deleting the `thumbs/` prefixes it created.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated authored changed lines | ~2,150-2,900 across 11 slices (code + tests + SQL + docs) |
| 400-line budget risk | High (total); per-slice High for 1, 4, 5b, 6a |
| Chained PRs recommended | Yes |
| Suggested split | PR1 slice 1 → PR2 slice 2 → PR3 slice 3 → PR4 slice 4 (+4b) → PR5 slice 5a → PR6 slice 5b → PR7 slice 6a → PR8 slice 6b → PR9 slice 7 → PR10 slice 8 |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

```text
Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High
```

### Per-slice budget

| Slice | Authored lines (est.) | Fits 400-line budget? | Notes |
|---|---|---|---|
| 1 Server thread read + seeding | 350-400 | Yes, **at the edge** | Measurement record TM1 adds 60-120 doc lines to this or the next PR; if 1 + TM1 exceeds 400, TM1 lands with slice 2 |
| 2 Signed-first bubbles + memo row | 250-330 | Yes | |
| 3 Scoped realtime + row patch | 200-280 | Yes | |
| 4 Virtualization | 330-400 | Yes, **at the edge** | TM2 doc lines pushed to slice 3's tail if needed |
| 4b Pre-fetch fix | Unknown | **Unforecastable** | Does not exist until the trace; sized after T1.0 |
| 5a Migration 400 | 220-300 | Yes | SQL + rollback + assertion |
| 5b Thumbnails at ingest + readers | 300-380 | Yes, **at the edge** | i18n keys add ~6 lines |
| 6a Insert-first + tail extraction + ordering | 330-400 | Yes, **at the edge** | The queue swap and invariant tests are the bulk |
| 6b Sweeper | 180-250 | Yes | |
| 7 Backfill | 250-330 | Yes | |
| 8 Retention + unavailable media | 150-250 | Yes | Plus a spec delta (not code) |

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | One request returns a page plus its signed media map | PR 1 | `npx vitest run src/app/api/inbox/messages/route.test.ts src/lib/storage/chat-media-server.test.ts src/lib/storage/signed-media.test.ts src/lib/inbox/thread-page.test.ts src/app/api/chat-media/sign/route.test.ts src/lib/storage/use-media-src.test.ts` | Staging panel, long PRUEBA thread, DevTools: no `/api/chat-media/sign` before first paint | Redeploy previous build (no data touched) |
| 2 | Signed-first, lazy, no-preload bubbles and a memoized row | PR 2 | `npx vitest run src/components/inbox/message-bubble.test.tsx src/components/inbox/thread-row.test.tsx` | Staging heavy PRUEBA thread, DevTools: zero `/api/chat-media/...` requests for chat-media items | Redeploy previous build |
| 3 | Filtered UPDATE subscription and identity-preserving row patch | PR 3 | `npx vitest run src/lib/inbox/patch-by-id.test.ts src/hooks/use-realtime.test.ts src/hooks/use-thread-realtime.test.ts src/components/inbox/message-thread.test.tsx` | Staging: two conversations, confirm the closed one delivers no UPDATEs to the open thread | Redeploy previous build |
| 4 | Virtualized thread with prepend-safe anchoring | PR 4 | `npx vitest run src/lib/inbox/thread-items.test.ts` | Staging long PRUEBA thread: open at bottom, older-page anchor, jump to quote, resync keeps position | Redeploy previous build |
| 4b | Pre-fetch latency fix, only if the trace proves it is in scope | PR 4 (or a follow-up PR) | Unknown until the slice exists | Re-run TM2 | Redeploy previous build |
| 5a | Additive media columns, pending index, sweeper claim function | PR 5 | `infra/db/staging-migracion.sh aplicar supabase/migrations/400_messages_media_metadata.sql supabase/staging/assertions/messages-media-metadata.sql supabase/migrations/ROLLBACK-400-messages-media-metadata.sql` (read-only runner) | Staging assertion ends `ALL PASS (rolled back on purpose)`; `relacionadas` shows no new DIFF | `ROLLBACK-400` (owner approval) |
| 5b | Thumbnails at ingest, metadata written, readers prefer them | PR 6 | `npx vitest run src/lib/storage/media-thumbnail.test.ts src/app/api/whatsapp/webhook/route.test.ts src/components/inbox/message-bubble.test.tsx` | Staging PRUEBA image: thumbnail object exists, panel row shows `pending` then `ready` | Redeploy; thumbnail objects are additive siblings |
| 6a | Insert-first ingest with the bot-facing tail gated on settlement | PR 7 | `npx vitest run src/app/api/whatsapp/webhook/route.test.ts src/lib/whatsapp/inbound-media.test.ts` | Staging PRUEBA inbound image with `ai_autoreply_disabled`; DB `media_status` transition | Redeploy previous webhook build; keep 6b deployed or run the sweeper once |
| 6b | Sweeper settles stale pending rows inside the Meta window | PR 8 | `npx vitest run src/lib/whatsapp/media-sweeper.test.ts src/app/api/cron/webhook-outbox/route.test.ts` | Staging: force a stale `pending` row by SQL, run the cron route, check settlement | Redeploy; no SQL of its own |
| 7 | Resumable backfill of metadata and thumbnails for retained history | PR 9 | `npx vitest run src/lib/storage/media-backfill.test.ts` | Staging dry run then real run; dry-run counters must equal the real-run counters | Column drop reverts it; `thumbs/` prefixes deletable |
| 8 | 90-day retention job and unavailable-media rendering | PR 10 | `npx vitest run src/lib/storage/media-retention.test.ts src/components/inbox/message-bubble.test.tsx src/app/api/cron/webhook-outbox/route.test.ts` | Staging dry run reporting the same count as the real run; purged object renders as unavailable | Redeploy; retention stops deleting once the call is removed |

## Slice dependency graph

```text
T1.0 trace ──> slice 1 ──> slice 2 ──> TM1 ──> slice 3 ──> slice 4 ──> TM2 ──> [G5] ──> slice 5a ──> [G4] ──> slice 5b ──> slice 6a ──> slice 6b ──> slice 7 ──> TM3 ──> slice 8
                                                        └──> 4b (conditional, only from the trace)
```

- Slices 1-4 touch no schema and no data. They ship and are measured in production before slice 5a, per the approved order (gate G5).
- Slice 5a must be applied in production before 5b and 6a write or read the new columns.
- 6a needs 5b (the settle path is what writes `ready`).
- 6b uses 5a's `crm_media_reclamar` and must stay deployed across any 6a rollback.
- 7 needs 5a applied. It is independent of 6a/6b: it only touches rows with `media_status IS NULL`.
- 8 is independent of 6a/6b/7 code-wise and can ship last; it uses the same private bucket and deletes by object age.
- Each slice is independently shippable because the readers fall back to `media_url` and the panel ignores unknown columns (`select('*')`).

---

## Slice 1 — Server thread read and signed media map (no schema)

Spec: `inbox-thread-read` (all six requirements), plus `chat-media-delivery` → "Private bucket, members-only access preserved" and "Media metadata compatibility" (readers only).

- [ ] **T1.0** Profile the pre-fetch window **before any code change** (ADR-10). Requirement: `inbox-thread-read` → "Thread fetch is not delayed by unrelated client work" (first half).
  - Goal: add temporary `performance.mark('inbox:select')` and `performance.mark('inbox:thread-fetch')` behind a `?perf=1` flag, record a Chrome DevTools Performance trace on the baseline method, and classify the 1.9 s gap as long tasks or idle awaiting against hypotheses (a)-(d).
  - Files: `src/app/(dashboard)/inbox/page.tsx`, `src/components/inbox/message-thread.tsx`, `openspec/changes/inbox-media-performance/measurements.md`
  - Test: none (profiling; the marks are removed before merge in T1.9).
  - Verify: `npx tsc --noEmit` and a written classification with the measured gap, stored in `openspec/changes/inbox-media-performance/measurements.md`. If hypothesis (a) — the supabase-js auth lock before the first PostgREST call — is confirmed, record that slice 1 is expected to remove it.

- [x] **T1.1** RED — thread page route cases. Requirement: `inbox-thread-read` → "Server-issued thread page", "Membership authorisation for signed media", "Signature lifetime and refresh path".
  - Goal: write failing tests for 401/403 passthrough, 400 cases (bad uuid, one cursor field only, cursor containing `,` or `)`, limit 0 and 101), 404 for a conversation of another account, the keyset `.or()` string built from the raw cursor, `limit + 1` setting `hasMore`, ascending response order, `signed` excluding foreign-account and non-chat-media URLs, signing failure returning 200 with `signed: {}`, and `Cache-Control: private, no-store`.
  - Files: `src/app/api/inbox/messages/route.test.ts` (new)
  - Test: itself.
  - Verify: `npx vitest run src/app/api/inbox/messages/route.test.ts` — must FAIL because the route does not exist.

- [x] **T1.2** RED — shared signer, seeding cache and synchronous first value. Requirement: `inbox-thread-read` → "Signature lifetime and refresh path"; `chat-media-delivery` → "Private bucket, members-only access preserved".
  - Goal: failing tests for `signChatMediaUrls` skipping foreign paths, deduping paths, mapping duplicate stored keys to every original key, and keeping the 3,600 s TTL; for seed → fresh peek, near-expiry peek returning null and re-signing, and invalidate forcing a re-sign; for the hook returning the seeded `src` on its first render; plus cursor-regex acceptance of PostgREST timestamps with microseconds and offsets and rejection of injection strings.
  - Files: `src/lib/storage/chat-media-server.test.ts`, `src/lib/storage/signed-media.test.ts`, `src/lib/storage/use-media-src.test.ts` (new), `src/lib/inbox/thread-page.test.ts` (new)
  - Test: those four files plus `src/app/api/chat-media/sign/route.test.ts` (must stay green).
  - Verify: `npx vitest run src/lib/storage/chat-media-server.test.ts src/lib/storage/signed-media.test.ts src/lib/storage/use-media-src.test.ts src/lib/inbox/thread-page.test.ts src/app/api/chat-media/sign/route.test.ts` — the new assertions FAIL.

- [x] **T1.3** GREEN — extract `signChatMediaUrls(urls, accountId, ttlSeconds)`. Requirement: `inbox-thread-read` → "Membership authorisation for signed media".
  - Goal: move the byPath/`createSignedUrls` logic out of the sign route into the storage server module, keeping `parseChatMediaPath` + `isChatMediaPathOfAccount` and the skip-and-log semantics; make the sign route delegate with an unchanged contract.
  - Files: `src/lib/storage/chat-media-server.ts`, `src/app/api/chat-media/sign/route.ts`
  - Test: `src/lib/storage/chat-media-server.test.ts`, `src/app/api/chat-media/sign/route.test.ts`
  - Verify: `npx vitest run src/lib/storage/chat-media-server.test.ts src/app/api/chat-media/sign/route.test.ts`

- [x] **T1.4** GREEN — `GET /api/inbox/messages`. Requirement: `inbox-thread-read` → "Server-issued thread page", "Membership authorisation for signed media".
  - Goal: implement the route exactly as ADR-1: `requireRole('viewer')`, parallel membership check and `limit + 1` keyset page, one `signChatMediaUrls` call for the page's chat-media `media_url` values, ascending rows, `hasMore`, `nextCursor`, `signed`, `expiresIn`, the documented error shapes, and the raw-cursor regexes (never `toISOString()`).
  - Files: `src/app/api/inbox/messages/route.ts` (new)
  - Test: `src/app/api/inbox/messages/route.test.ts`
  - Verify: `npx vitest run src/app/api/inbox/messages/route.test.ts`

- [x] **T1.5** GREEN — cursor and client helper contracts. Requirement: `inbox-thread-read` → "Pagination is cursor-based and newest first".
  - Goal: implement `ThreadCursor`, `ThreadPageResponse`, the cursor regexes and `fetchThreadPage(conversationId, cursor?, limit?)` in the shared module.
  - Files: `src/lib/inbox/thread-page.ts` (new)
  - Test: `src/lib/inbox/thread-page.test.ts`
  - Verify: `npx vitest run src/lib/inbox/thread-page.test.ts`

- [x] **T1.6** GREEN — `seedSignedMedia`, `peekSignedMediaSrc`, `invalidateSignedMedia`, and a synchronous first value. Requirement: `inbox-thread-read` → "Signature lifetime and refresh path".
  - Goal: add the three exports keyed by the stored URL string with `expiresAt = receivedAt + expiresIn*1000`; keep `resolveMediaSrc` and `REFRESH_MARGIN_MS` unchanged; make `useMediaSrc` initialise from the peek and skip the async resolve when fresh, so a seeded bubble renders its `src` on the first render with no null-then-src flash.
  - Files: `src/lib/storage/signed-media.ts`, `src/lib/storage/use-media-src.ts`
  - Test: `src/lib/storage/signed-media.test.ts`, `src/lib/storage/use-media-src.test.ts`
  - Verify: `npx vitest run src/lib/storage/signed-media.test.ts src/lib/storage/use-media-src.test.ts`

- [x] **T1.7** GREEN — thread loads through the route and seeds before rendering. Requirement: `inbox-thread-read` → "Opening a conversation needs one round-trip for messages and media".
  - Goal: replace the client PostgREST page query with `fetchThreadPage`, call `seedSignedMedia(signed, expiresIn)` before `onMessagesLoaded(rows)` and before prepending an older page.
  - Files: `src/components/inbox/message-thread.tsx`
  - Test: `src/components/inbox/message-thread.test.tsx` (created in T3.1; for slice 1, add a case that the first page is requested once and seeded before rows render)
  - Verify: `npx vitest run src/components/inbox/message-thread.test.tsx`

- [x] **T1.8** Verification and staging check. Requirement: `inbox-thread-read` → "Opening a conversation needs one round-trip for messages and media".
  - Status 2026-11-27: suite and `tsc` green (see `apply-progress`). The staging browser check is **not run** — it was explicitly out of scope for the apply run and stays pending for the orchestrator's staging pass.
  - Goal: full suite plus `tsc`, then a staging panel check per `.claude/skills/wacrm-probar-staging/SKILL.md` (read-only): open a long PRUEBA thread of the current build and confirm no `/api/chat-media/sign` request precedes first paint and media still renders.
  - Files: none.
  - Test: the slice-1 files above.
  - Verify: `npx vitest run src/app/api/inbox/messages/route.test.ts src/lib/storage/chat-media-server.test.ts src/lib/storage/signed-media.test.ts src/lib/storage/use-media-src.test.ts src/lib/inbox/thread-page.test.ts src/app/api/chat-media/sign/route.test.ts src/components/inbox/message-thread.test.tsx && npx tsc --noEmit`

- [ ] **T1.9** REFACTOR — remove the temporary perf marks and record the trace. Requirement: `inbox-thread-read` → "Thread fetch is not delayed by unrelated client work".
  - Goal: delete the `?perf=1` marks from the two components, record the classification and the before numbers in `openspec/changes/inbox-media-performance/measurements.md`, and record whether slice 1 removed the observed cause.
  - Files: `src/app/(dashboard)/inbox/page.tsx`, `src/components/inbox/message-thread.tsx`, `openspec/changes/inbox-media-performance/measurements.md`
  - Test: none (the marks must be gone; `grep -n "inbox:select" src/app/(dashboard)/inbox/page.tsx` returns nothing).
  - Verify: `npx tsc --noEmit && npm test`

## Slice 2 — Signed-first bubbles, lazy images, no preload, memoized row (no schema)

Spec: `chat-media-delivery` → "Direct signed delivery", "One download per media item", "Proxy is fallback only", "Play-on-demand audio and video", "Thumbnails with reserved dimensions and lazy loading" (lazy + reserved box part, before thumbnails exist), "No Storage transformations, no re-encoding" (originals untouched); `inbox-realtime` → "Memoized bubbles and scoped grouping" (memoized part).

- [x] **T2.1** RED — bubble delivery and failure cases. Requirement: as above.
  - Goal: failing tests that a seeded image renders the signed `src` on the first render; video, audio and document never render a `/api/chat-media/` source before resolution; `preload="none"`; `loading="lazy"` plus the reserved `h-40 w-60` box; a media `error` re-signs exactly once and then falls back; legacy `/api/whatsapp/media/<id>` behaviour is unchanged.
  - Files: `src/components/inbox/message-bubble.test.tsx`
  - Test: itself.
  - Verify: `npx vitest run src/components/inbox/message-bubble.test.tsx` — new cases FAIL.

- [x] **T2.2** RED — row memoization. Requirement: `inbox-realtime` → "Unrelated state change does not re-render bubbles".
  - Goal: failing `React.Profiler` render-count assertions: equal props do not re-render the row; a changed message re-renders only that row.
  - Files: `src/components/inbox/thread-row.test.tsx` (new)
  - Test: itself.
  - Verify: `npx vitest run src/components/inbox/thread-row.test.tsx` — FAIL.

- [x] **T2.3** GREEN — `ThreadRow`. Requirement: `inbox-realtime` → "Unrelated state change does not re-render bubbles".
  - Goal: create the memoized row taking `message`, `replyParent?`, `reactions?`, `currentUserId`, `highlighted` and **stable id-based** callbacks `onReply(message)`, `onReact(messageId, emoji)`, `onTogglePill(messageId, emoji)`, `onJump(messageId)`; compute the reply label and preview inside the row.
  - Files: `src/components/inbox/thread-row.tsx` (new)
  - Test: `src/components/inbox/thread-row.test.tsx`
  - Verify: `npx vitest run src/components/inbox/thread-row.test.tsx`

- [x] **T2.4** GREEN — bubble source selection. Requirement: `chat-media-delivery` → "Direct signed delivery", "One download per media item", "Proxy is fallback only", "Play-on-demand audio and video".
  - Goal: implement ADR-3 rules 2-4: remove `resolvedMedia ?? toChatMediaSrc(media_url)` as a first source for video, audio and documents; render sized placeholders while unresolved; `preload="none"` for audio and video; images lazy with `decoding="async"` and the reserved box; `error` → `invalidateSignedMedia` and one re-resolve, then the proxy; export the component wrapped in `React.memo`.
  - Files: `src/components/inbox/message-bubble.tsx`
  - Test: `src/components/inbox/message-bubble.test.tsx`
  - Verify: `npx vitest run src/components/inbox/message-bubble.test.tsx`

- [x] **T2.5** GREEN — thread renders `ThreadRow` with stable callbacks. Requirement: `inbox-realtime` → "Memoized bubbles and scoped grouping".
  - Goal: replace the inline bubble rendering with `ThreadRow` and hoist the callbacks so their identity does not change per render.
  - Files: `src/components/inbox/message-thread.tsx`
  - Test: `src/components/inbox/message-thread.test.tsx`, `src/components/inbox/thread-row.test.tsx`
  - Verify: `npx vitest run src/components/inbox/message-thread.test.tsx src/components/inbox/thread-row.test.tsx`

- [x] **T2.6** Verification and staging check.
  - Status 2026-11-27: slice-2 tests, full suite and `tsc` green (see `apply-progress`). The staging browser check is **not run** — it was explicitly out of scope for the apply run and stays pending for the orchestrator's staging pass.
  - Goal: full suite, `tsc`, then a staging heavy PRUEBA thread with DevTools: zero `/api/chat-media/...` requests for chat-media items, no duplicate downloads, audio/video transferring nothing before play.
  - Files: none.
  - Test: slice-2 files.
  - Verify: `npx vitest run src/components/inbox/message-bubble.test.tsx src/components/inbox/thread-row.test.tsx src/components/inbox/message-thread.test.tsx && npx tsc --noEmit`

### Slice 2 review corrections (2026-11-27)

Filed under slice 2 because they repair slice-2 behaviour; no new PR slice.

- [x] **T2.7** Media error recovery for video, audio and the document link: on `error`, `invalidateSignedMedia(url)`, one re-resolve through `resolveMediaSrc`, then the proxy; a failing fallback renders the unavailable state. One re-sign per element per mount.
- [x] **T2.8** One failure is enough to show the unavailable state: when the re-resolved URL equals the failing URL or the re-sign yields nothing, render `MediaUnavailable` immediately instead of waiting for an `error` React never re-fires. The image branch no longer dead-ends on a broken glyph.
- [x] **T2.9** Seeded images paint on the true first render: `loading` initialises from `peekSignedMediaSrc` instead of from `!isMetaMedia`, so no `MediaLoadingBox` commit precedes a seeded `<img>`. The legacy Meta blob path keeps its async loading state.
- [x] **T2.10** Integration-level memo proof: `message-thread.test.tsx` renders the real `MessageThread` and the real `ThreadRow`, and asserts an unrelated `isRefreshing` change does not re-render untouched rows.

## Measurement 1 — after slices 1-2 (own task)

- [ ] **TM1** Re-run the baseline method and record the numbers. Requirement: `inbox-thread-read` → "First-page performance budget", "Measurement record"; `chat-media-delivery` → "One download per media item".
  - Goal: fresh session, the same heaviest conversation, the same 50-message page, DevTools network + performance timeline. Record: click → page request start, `/api/chat-media/...` request count (baseline 29), sign request start and duration, first signed Storage URL start (baseline 5.6 s), first-page media bytes (baseline 5.3 MB), and the pre-fetch gap between the two marks. Staging first; production only under gate G3.
  - Files: `openspec/changes/inbox-media-performance/measurements.md`
  - Test: none (measurement).
  - Verify: every number above has a value or is explicitly reported as **unmeasured** — never as met. Result is committed with slice 2's PR tail if slice 1 is already at the 400-line edge.

## Slice 3 — Scoped realtime and row-level patching (no schema)

Spec: `inbox-realtime` → "Per-conversation message subscription", "Row-level conversation list patching", "Memoized bubbles and scoped grouping" (grouping part).

- [x] **T3.1** RED — `patchById` and subscription shapes. Requirement: `inbox-realtime` → "Per-conversation message subscription", "Row-level conversation list patching".
  - Goal: failing tests for `patchById` returning the same reference when the id is absent or the patch is equal, and a single-element replacement otherwise; for `useRealtime` subscribing `messages` with `event: 'INSERT'` only and `conversations` with `'*'`; for the new thread channel using `filter: 'conversation_id=eq.<id>'` with `event: 'UPDATE'` and being torn down on id change and unmount; and for grouping reused when the message list did not change.
  - Files: `src/lib/inbox/patch-by-id.test.ts` (new), `src/hooks/use-realtime.test.ts` (new), `src/hooks/use-thread-realtime.test.ts` (new), `src/components/inbox/message-thread.test.tsx` (extend)
  - Test: those four.
  - Verify: `npx vitest run src/lib/inbox/patch-by-id.test.ts src/hooks/use-realtime.test.ts src/hooks/use-thread-realtime.test.ts src/components/inbox/message-thread.test.tsx` — FAIL.

- [x] **T3.2** GREEN — `patchById` and `useThreadRealtime`. Requirement: `inbox-realtime` → "Per-conversation message subscription", "Row-level conversation list patching".
  - Goal: implement the identity-preserving patch and the filtered per-conversation UPDATE channel exactly as ADR-5.
  - Files: `src/lib/inbox/patch-by-id.ts` (new), `src/hooks/use-thread-realtime.ts` (new)
  - Test: `src/lib/inbox/patch-by-id.test.ts`, `src/hooks/use-thread-realtime.test.ts`
  - Verify: `npx vitest run src/lib/inbox/patch-by-id.test.ts src/hooks/use-thread-realtime.test.ts`

- [x] **T3.3** GREEN — narrow `useRealtime` to INSERTs. Requirement: `inbox-realtime` → "Per-conversation message subscription" (deviation note in ADR-5: INSERTs stay account-wide for the chat sound and list preview).
  - Goal: keep `messages` on `event: 'INSERT'` only and leave `conversations` on `'*'`.
  - Files: `src/hooks/use-realtime.ts`
  - Test: `src/hooks/use-realtime.test.ts`
  - Verify: `npx vitest run src/hooks/use-realtime.test.ts src/hooks/use-chat-message-sound.test.tsx src/lib/inbox/chat-sound-gate.test.ts "src/app/(dashboard)/inbox/page.test.tsx"` (existing sound behaviour and the page wiring must stay green)

- [x] **T3.4** GREEN — wire the inbox page. Requirement: `inbox-realtime` → "Row-level conversation list patching", "Unread counts and last message stay live".
  - Goal: use `patchById` for message UPDATE, conversation UPDATE, the INSERT preview patch and the status/assign/not-business handlers; wire `useThreadRealtime` for the open conversation; memoize grouping with `useMemo` on `displayMessages`.
  - Files: `src/app/(dashboard)/inbox/page.tsx`, `src/components/inbox/message-thread.tsx`
  - Test: `src/components/inbox/message-thread.test.tsx`, `src/lib/inbox/patch-by-id.test.ts`
  - Verify: `npx vitest run src/components/inbox/message-thread.test.tsx src/lib/inbox/patch-by-id.test.ts src/lib/inbox/chat-sound-gate.test.ts`

- [x] **T3.5** Verification and staging check.
  - Status 2026-11-27: slice-3 tests, full suite and `tsc` green (see `apply-progress`). The staging browser check is **not run** — it was explicitly out of scope for the apply run and stays pending for the orchestrator's staging pass.
  - Goal: suite and `tsc`, then staging with two conversations: the closed one produces no UPDATE delivery to the open thread, and the list patches one row while unread counts stay live.
  - Files: none.
  - Test: slice-3 files.
  - Verify: `npx vitest run src/lib/inbox/patch-by-id.test.ts src/hooks/use-realtime.test.ts src/hooks/use-thread-realtime.test.ts src/components/inbox/message-thread.test.tsx && npx tsc --noEmit`

## Slice 4 — Virtualized thread (no schema)

Spec: `inbox-realtime` → "Virtualized thread" (all five scenarios).

- [x] **T4.1** RED — prepend-safe item model. Requirement: `inbox-realtime` → "Only visible messages are mounted", "Older page loads at the top", "Jump to message works".
  - Goal: failing tests for separators rendered **below** the last message of a day at day boundaries, existing items staying deep-equal after prepending N same-day or other-day messages, `nextFirstItemIndex(prev, n)`, and `indexOfMessage` in the index space the installed `react-virtuoso` actually uses.
  - Files: `src/lib/inbox/thread-items.test.ts` (new)
  - Test: itself.
  - Verify: `npx vitest run src/lib/inbox/thread-items.test.ts` — FAIL.

- [x] **T4.2** GREEN — item model and the dependency. Requirement: `inbox-realtime` → "Virtualized thread".
  - Goal: add `react-virtuoso` 4.x (MIT `Virtuoso` only, never `@virtuoso.dev/message-list`), confirm its React 19.2 peer range and the `scrollToIndex` index space against `node_modules/react-virtuoso/README.md` (read-only), and implement `ThreadItem`, `buildThreadItems`, `nextFirstItemIndex` and `indexOfMessage`.
  - Files: `src/lib/inbox/thread-items.ts` (new), `package.json`
  - Test: `src/lib/inbox/thread-items.test.ts`
  - Verify: `npx vitest run src/lib/inbox/thread-items.test.ts`

- [x] **T4.3** GREEN — Virtuoso thread. Requirement: `inbox-realtime` → "Virtualized thread", "Scroll-to-bottom on open", "New message keeps the view anchored".
  - Goal: map the current behaviours per ADR-4 (`initialTopMostItemIndex` LAST + `key={conversationId}`, `followOutput`, `startReached`, `firstItemIndex` decrease on prepend, `scrollToIndex` + `highlightId` for 1,600 ms, `computeItemKey`); render the oldest day's separator in `components.Header`; make the "loading older" indicator an absolute overlay; make resync merge by id and no longer clear `olderMessages`.
  - Files: `src/components/inbox/message-thread.tsx`
  - Test: `src/components/inbox/message-thread.test.tsx`, `src/lib/inbox/thread-items.test.ts`
  - Verify: `npx vitest run src/components/inbox/message-thread.test.tsx src/lib/inbox/thread-items.test.ts`

- [ ] **T4.4** Browser check on staging (behaviour is the acceptance criterion).
  - Status 2026-11-27: **not run** — explicitly out of scope for this apply run; stays pending for the orchestrator's staging pass. jsdom cannot measure items, so open-at-bottom, prepend-anchor, jump centring, resync position and follow-tail are NOT asserted by unit tests; they are this task.
  - Goal: long PRUEBA thread: opens at the bottom; scrolling to the top loads the next older page without a jump; jump-to-quote mounts and centres the target; a resync keeps position and does not shrink loaded history; a new message follows the tail. Any regression is a defect, not a trade-off.
  - Files: none.
  - Test: manual, per `.claude/skills/wacrm-probar-staging/SKILL.md` (read-only).
  - Verify: record the four observed behaviours in the PR description; `npx tsc --noEmit`.

- [x] **T4.5** Verification.
  - Status 2026-11-27: slice-4 focused tests, full suite and `tsc` green (see `apply-progress`). The "only visible rows mounted on open" check needs a real layout and is deferred to T4.4.
  - Goal: full suite and `tsc`; confirm only the visible rows are mounted on open.
  - Files: none.
  - Test: slice-4 files.
  - Verify: `npx vitest run src/lib/inbox/thread-items.test.ts src/components/inbox/message-thread.test.tsx src/components/inbox/thread-row.test.tsx && npx tsc --noEmit`

### Slice 4 review corrections (2026-11-27)

Filed under slice 4 because they repair slice-4 behaviour; no new PR slice. T4.4 (staging browser check) still covers the layout behaviours that jsdom cannot measure.

- [x] **T4.6** BLOCKER — day labels come from the original instant. `buildThreadItems` now exposes `headerDayAt` / `separatorBelowAt`; `formatThreadDayLabel` evaluates `today`/`yesterday` in the viewer's local calendar instead of re-parsing the `yyyy-MM-dd` grouping key as UTC midnight. Regression test runs under `America/Havana` (component header + separator) and as a pure function in `thread-items.tz.test.ts`; both failed pre-fix.
- [x] **T4.7** BLOCKER — resync cannot leave an unreachable hole. `newestPageLeavesGap` compares the resynced page's oldest message with the newest message of the page being replaced; on a non-overlap the retained `olderMessages` (and the anchor) are dropped so the next top-reach backfills from the new boundary. Overlapping resyncs keep history. Tests cover both branches and the backfill cursor.
- [x] **T4.8** should-fix — `followOutput` follows the tail only when the agent is already at the bottom (`isAtBottom ? "auto" : false`). Unit test asserts the policy passed to Virtuoso; the real scroll behaviour remains T4.4.
- [x] **T4.9** should-fix — `itemContent` (and `followOutput`) are `useCallback`-stable, so Virtuoso item memoization is not defeated by a fresh arrow per render. Test asserts reference identity across an unrelated re-render.
- [x] **T4.10** nit — `itemsRef`, `firstItemIndexRef` and `reactionsRef` are written in effects, never during render, matching the file's React 19 convention.
- [x] **T4.11** test-double honesty — the Virtuoso double fires `startReached` on any scroll. The test that relied on it is renamed and annotated as wiring-only, and the file header lists the layout behaviours that stay staging-only.
- [x] **T4.12** BLOCKER — the empty state returned before five thread hooks (`renderItem`, `renderItemContent`, `followOutput`, `headerContext`, `virtuosoComponents`), so the first render ran fewer hooks than the next and opening the first conversation threw React #310 ("Rendered more hooks than during the previous render") into the error boundary. The empty-state return now sits after every hook, immediately before the main JSX return; `displayName`, `currentStatus` and `assignedAgentId` were made null-safe to survive the reorder. Regression test mounts with `conversation={null}`/`contact={null}`, asserts the empty state, then re-renders the SAME root with a real conversation and asserts it does not throw; it failed pre-fix with the exact #310 error. Audit of `message-bubble.tsx`, `thread-row.tsx`, `(dashboard)/inbox/page.tsx` found no other return-before-hook.
- Verify: `npx vitest run src/lib/inbox/thread-items.test.ts src/components/inbox/message-thread.test.tsx && npx tsc --noEmit`; `thread-items.tz.test.ts` is also run (non-UTC regression, not in the original focused list).

## Measurement 2 — after slice 4 (own task)

- [x] **TM2** Re-run the baseline method. Requirement: `inbox-thread-read` → "First-page performance budget", "Measurement record"; `inbox-realtime` → "Only visible messages are mounted".
  - Goal: same method as TM1; also record the mounted-message count on open and the proxy request count.
  - Files: `openspec/changes/inbox-media-performance/measurements.md`
  - Test: none.
  - Verify: numbers recorded with a date, or reported unmeasured. This is the last measurement before the schema slices; gate G5 reads it.
  - **Done 2026-11-27**: cold open messages 632 ms / first media 786 ms; repeats 372–552 ms / 501–675 ms; 4 media objects, 0 proxy, 684 KB. Recorded in `measurements.md`.

## Slice 4c — Remove round trips from the thread page (no schema)

Evidence: after TM2 the endpoint's 372–632 ms decomposed into a chain of four serial network stages — profile, accounts, (membership ∥ page), signing. Profiling against staging showed the signing call costs a fixed ~100–160 ms whether it carries 10 or 55 paths, and splitting it into parallel chunks is worse, so the batch size was never the problem.

- [x] **T4c.1** GATE — locate the cost before changing anything. Requirement: `inbox-thread-read` → "First-page performance budget".
  - Goal: separate page query, signing and auth in a standalone read-only profile; refuse any fix that does not follow from it.
  - Files: none in the repo (scratch script only).
  - Test: none (measurement task).
  - Verify: recorded numbers. Result: page 99–213 ms, sign 92–157 ms for both 10 and 55 paths, auth residual ~180 ms (two point queries).
- [x] **T4c.2** Context without the `accounts` lookup. Requirement: `inbox-thread-read` → "First-page performance budget".
  - Goal: `requireScopedRole(min)` resolves identity, account id and role from `profiles` alone; the thread route uses it. `requireRole` keeps its full contract for every existing caller.
  - Files: `src/lib/auth/account.ts`, `src/app/api/inbox/messages/route.ts`, `src/lib/auth/account.test.ts`
  - Test: profile-only table access; role gate; unauthorized; unlinked profile.
  - Verify: RED observed (`requireScopedRole is not a function`), then GREEN; `tsc --noEmit` clean.
- [x] **T4c.3** Reuse still-valid signatures. Requirement: `chat-media-delivery` → "Signed media map".
  - Goal: cache issued signatures by account + path; reuse only while the remaining life covers the requested TTL; never cache a failure; bound the map.
  - Files: `src/lib/storage/chat-media-server.ts`, `src/lib/storage/chat-media-server.test.ts`
  - Test: reuse without a Storage call; partial miss signs only what is missing; expiry re-signs; failure is not cached.
  - Verify: RED observed (`__resetSignCache is not a function`), then GREEN.
- [x] **T4c.4** Re-measure after 4c. Requirement: `inbox-thread-read` → "Measurement record".
  - Goal: same method and fixture as TM2.
  - Files: `openspec/changes/inbox-media-performance/measurements.md`
  - Test: none.
  - Verify: repeat endpoint median 469 → 295 ms, first media median 595 → 415 ms; cold open unchanged (632 → 696 ms, within noise).

## Slice 4b — Pre-fetch fix, conditional (no schema)

Design: ADR-10 leaves 4b empty until the trace exists. This slice must not be invented.

- [ ] **T4b.1** GATE — decide 4b from the TM1/TM2 evidence. Requirement: `inbox-thread-read` → "Thread fetch is not delayed by unrelated client work".
  - Goal: using the T1.0 and TM2 traces, either (a) confirm the cause was removed and close 4b as "not needed", with the evidence recorded, or (b) append a design note to `openspec/changes/inbox-media-performance/design.md` naming the cause and the fix, and add tasks T4b.2..n with their tests. If the cause is outside the inbox (layout, auth bundle), report it and change nothing.
  - Files: `openspec/changes/inbox-media-performance/design.md`
  - Test: none (decision task).
  - Verify: the decision and its evidence are recorded; no code change is made in this task.

## Slice 5a — Migration 400: media metadata (schema)

Spec: `media-ingest` → "Additive media metadata columns"; `chat-media-delivery` → "Media metadata compatibility", "Existing media_url readers are unaffected".

- [ ] **T5a.1** Re-check the next free migration number before writing anything. Requirement: `media-ingest` → "Additive media metadata columns".
  - Goal: run the multi-branch command from `.claude/skills/wacrm-migraciones/references/workflow.md` (read-only) plus production's `schema_migrations` names, and confirm 400 is free on every branch and in production. If it is taken, renumber the migration, rollback and assertion consistently, and record the number actually used in the PR.
  - Files: none.
  - Test: none.
  - Verify: `git for-each-ref --format='%(refname)' refs/heads | while read r; do git ls-tree --name-only "$r" supabase/migrations/; done | grep -oE '[0-9]{3}_' | sort -u | tail -5` — 400 absent.

- [ ] **T5a.2** GATE — slice order and production measurement. Requirement: `inbox-thread-read` → "Measurement record".
  - Goal: confirm slices 1-4 are shipped and measured in production (TM1, TM2 with numbers recorded) before any schema work starts, per the approved order. If the measurement is missing, stop and report it as unmeasured.
  - Files: none.
  - Test: none.
  - Verify: `openspec/changes/inbox-media-performance/measurements.md` holds TM1 and TM2 with dates.

- [ ] **T5a.3** RED — self-reverting assertion (the failing test comes first). Requirement: `media-ingest` → "Additive media metadata columns".
  - Goal: write the eight ADR-6 cases (legacy insert gets NULL + `media_attempts = 0`; `'bogus'` rejected; claimed-10-minutes-ago returned as `reintentar` with attempts +1; claimed-1-minute-ago not returned; attempts ≥ 3 → `failed`/`fallida`; older than 7 days → `failed` with `meta window expired`; `ready` and NULL rows untouched; `authenticated` has no EXECUTE), ending `RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'`.
  - Files: `supabase/staging/assertions/messages-media-metadata.sql` (new)
  - Test: itself (run against staging before the migration: it must FAIL because no column or function exists).
  - Verify: `infra/db/staging-migracion.sh` with the assertion, expected FAIL.

- [ ] **T5a.4** GREEN — the migration. Requirement: `media-ingest` → "Additive media metadata columns"; `chat-media-delivery` → "Media metadata compatibility".
  - Goal: add the ten nullable/defaulted columns from ADR-6 (no `BEGIN/COMMIT`), the `messages_media_status_check` constraint `NOT VALID` then `VALIDATE`, `idx_messages_media_pending`, and `public.crm_media_reclamar(p_limit int DEFAULT 5, p_stale interval DEFAULT '5 minutes')` as `SECURITY DEFINER SET search_path = public` with `REVOKE ALL … FROM PUBLIC, anon, authenticated; GRANT EXECUTE … TO service_role`. Keep text + CHECK (no enum).
  - Files: `supabase/migrations/400_messages_media_metadata.sql` (new; final number from T5a.1)
  - Test: the assertion from T5a.3.
  - Verify: staging cycle step in T5a.5.

- [ ] **T5a.5** GREEN — rollback script and staging cycle. Requirement: `media-ingest` → "Rollback is clean", "Existing readers show no new diff".
  - Goal: write `supabase/migrations/ROLLBACK-400-messages-media-metadata.sql` (drop function, index, constraint and all ten columns), then run `staging-migracion.sh aplicar` with no function list (none redefined), then `relacionadas 400_messages_media_metadata.sql media_url` (must show **no new DIFF**), then the assertion (must end `ALL PASS (rolled back on purpose)`).
  - Files: `supabase/migrations/ROLLBACK-400-messages-media-metadata.sql` (new)
  - Test: `supabase/staging/assertions/messages-media-metadata.sql`
  - Verify: `infra/db/staging-migracion.sh aplicar supabase/migrations/400_messages_media_metadata.sql supabase/staging/assertions/messages-media-metadata.sql supabase/migrations/ROLLBACK-400-messages-media-metadata.sql` (read-only runner), then `infra/db/staging-migracion.sh relacionadas 400_messages_media_metadata.sql media_url` (read-only runner): report OK/FAIL, `VEREDICTO`, and the DIFF result.

- [ ] **T5a.6** GATE — production go-ahead for migration 400. Requirement: `media-ingest` → "Additive media metadata columns".
  - Goal: run `produccion-migracion.sh previa` for all pending files in order, show the owner the verdict and any `DIFFERENT`/`MISSING-IN-PROD`/`EXTRA-IN-PROD` diff, and wait for an **explicit, per-apply** go-ahead. Earlier approvals do not carry over.
  - Files: none.
  - Test: none.
  - Verify: `infra/db/produccion-migracion.sh previa supabase/migrations/400_messages_media_metadata.sql` (read-only runner) reports `SEGURO` or `RECORDED`, and the owner's answer is recorded in the PR.

- [ ] **T5a.7** GATE-blocked — apply and verify in production (only after T5a.6).
  - Goal: `aplicar` then `verificar` the same file list; report `OK <name> <version>` lines and `VERIFICADO: n/n`. On any mismatch, stop and report; never roll back on your own.
  - Files: none.
  - Test: none.
  - Verify: `infra/db/produccion-migracion.sh aplicar supabase/migrations/400_messages_media_metadata.sql` then `infra/db/produccion-migracion.sh verificar supabase/migrations/400_messages_media_metadata.sql` (read-only runners).

## Slice 5b — Thumbnails at ingest and readers prefer them

Spec: `media-ingest` → "Thumbnails generated at ingest", "Originals are never re-encoded"; `chat-media-delivery` → "Thumbnails with reserved dimensions and lazy loading", "Pending and failed media states are visible", "No Storage transformations, no re-encoding".

- [ ] **T5b.1** RED — thumbnail module. Requirement: `media-ingest` → "Thumbnails generated at ingest"; `chat-media-delivery` → "No Storage transformations, no re-encoding".
  - Goal: failing tests for the path convention `account-<uuid>/thumbs/<base>.webp`, rejection of unsafe paths, a real `sharp` run on a tiny PNG fixture producing WebP with longest side ≤ 360 and the original dimensions, non-images returning `null`, corrupt bytes returning `{ error }`, and the original buffer being unchanged after thumbnailing.
  - Files: `src/lib/storage/media-thumbnail.test.ts` (new)
  - Test: itself.
  - Verify: `npx vitest run src/lib/storage/media-thumbnail.test.ts` — FAIL.

- [ ] **T5b.2** RED — ingest writes metadata and `ready`. Requirement: `media-ingest` → "Ready or failed transition", "Successful ingestion becomes ready".
  - Goal: failing tests that a persisted image writes `media_*` plus `ready`, and that a thumbnail failure still yields `ready` with `media_error` and no thumbnail path.
  - Files: `src/app/api/whatsapp/webhook/route.test.ts`
  - Test: itself.
  - Verify: `npx vitest run src/app/api/whatsapp/webhook/route.test.ts` — new cases FAIL.

- [ ] **T5b.3** RED — bubble prefers the thumbnail and renders pending/failed. Requirement: `chat-media-delivery` → "Thumbnail first, full object on open", "Missing thumbnail falls back", "Pending media shows a downloading state", "Failed media shows a failure state".
  - Goal: failing tests for the thumbnail `src` preferred with explicit `width`/`height`, the original resolved only on zoom, the fallback chain when there is no thumbnail, and the pending and failed copy (the Spanish strings are gate G2).
  - Files: `src/components/inbox/message-bubble.test.tsx`
  - Test: itself.
  - Verify: `npx vitest run src/components/inbox/message-bubble.test.tsx` — new cases FAIL.

- [ ] **T5b.4** GREEN — explicit `sharp` dependency and a build proof. Requirement: `media-ingest` → "Thumbnail generation MUST use `sharp` as an explicit dependency".
  - Goal: add `sharp` to `dependencies`, then verify it loads inside the standalone build on the production host before 5b ships; if it cannot load, stop and report (thumbnail failure degrades, but the dependency must be deliberate).
  - Files: `package.json`, `package-lock.json`
  - Test: `src/lib/storage/media-thumbnail.test.ts` exercises the real `sharp`.
  - Verify: `npx vitest run src/lib/storage/media-thumbnail.test.ts && npm run build`

- [ ] **T5b.5** GREEN — `thumbnailPathFor` and `makeThumbnail`. Requirement: `media-ingest` → "Thumbnail is a sibling in the same prefix", "Stickers get thumbnails too", "Thumbnail failure is non-fatal".
  - Goal: implement the deterministic sibling naming, dynamic `import('sharp')`, `.rotate()`, WebP q65, longest side 360, first frame only; return `null` for non-images and `{ error }` on failure. Never touch the original bytes.
  - Files: `src/lib/storage/media-thumbnail.ts` (new)
  - Test: `src/lib/storage/media-thumbnail.test.ts`
  - Verify: `npx vitest run src/lib/storage/media-thumbnail.test.ts`

- [ ] **T5b.6** GREEN — message type fields. Requirement: `chat-media-delivery` → "Media metadata compatibility".
  - Goal: add the optional `media_*` fields from the interfaces block to `Message`.
  - Files: `src/types/index.ts`
  - Test: `npx tsc --noEmit` plus the bubble tests.
  - Verify: `npx tsc --noEmit`

- [ ] **T5b.7** GREEN — ingest writes the metadata (order unchanged in this slice). Requirement: `media-ingest` → "Ready or failed transition", "Originals are never re-encoded"; `chat-media-delivery` → "Media metadata compatibility".
  - Goal: extend `persistMedia` so the stored image writes `media_path`, `media_thumb_path`, `media_mime`, `media_bytes`, `media_width`, `media_height`, `media_status = 'ready'` and `media_error`; the older proxy `media_url` write stays exactly as today and the original upload stays byte-identical.
  - Files: `src/app/api/whatsapp/webhook/route.ts`
  - Test: `src/app/api/whatsapp/webhook/route.test.ts`
  - Verify: `npx vitest run src/app/api/whatsapp/webhook/route.test.ts`

- [ ] **T5b.8** GREEN — the route also signs thumbnail proxy URLs. Requirement: `chat-media-delivery` → "Thumbnail first, full object on open"; `inbox-thread-read` → "Signature lifetime and refresh path".
  - Goal: include `chatMediaProxyUrl(media_thumb_path)` values in the same single `signChatMediaUrls` call, keyed exactly as the client resolves them.
  - Files: `src/app/api/inbox/messages/route.ts`
  - Test: `src/app/api/inbox/messages/route.test.ts` (extend with the thumbnail key case)
  - Verify: `npx vitest run src/app/api/inbox/messages/route.test.ts`

- [ ] **T5b.9** GREEN — bubble renders thumbnails, dimensions and states. Requirement: `chat-media-delivery` → "Thumbnail first, full object on open", "Missing thumbnail falls back", "Pending media shows a downloading state", "Failed media shows a failure state".
  - Goal: implement ADR-3 rule 1 and the image branch of rule 2: thumbnail first with `width`/`height` from `media_width`/`media_height` and `h-auto max-h-64 max-w-60 object-cover`; fixed `h-40 w-60` when null; pending placeholder; failed state keeping the legacy proxy URL as the last fallback; zoom resolves the original only on open.
  - Files: `src/components/inbox/message-bubble.tsx`
  - Test: `src/components/inbox/message-bubble.test.tsx`
  - Verify: `npx vitest run src/components/inbox/message-bubble.test.tsx`

- [ ] **T5b.10** GATE-blocked — Spanish copy keys (only after G2). Requirement: `chat-media-delivery` → "Pending media shows a downloading state", "Failed media shows a failure state".
  - Goal: add `Inbox.bubble.mediaPending` and `Inbox.bubble.mediaFailed` to both locales with the owner-confirmed Spanish strings. Do not invent copy.
  - Files: `messages/es.json`, `messages/en.json`
  - Test: `src/components/inbox/message-bubble.test.tsx` (asserts the keys render)
  - Verify: `npx vitest run src/components/inbox/message-bubble.test.tsx && npx tsc --noEmit`

- [ ] **T5b.11** Verification and staging check.
  - Goal: suite and `tsc`, then a staging PRUEBA image: a thumbnail sibling exists under the account prefix, the original is byte-identical, the panel shows `pending` then `ready`.
  - Files: none.
  - Test: slice-5b files.
  - Verify: `npx vitest run src/lib/storage/media-thumbnail.test.ts src/app/api/whatsapp/webhook/route.test.ts src/components/inbox/message-bubble.test.tsx src/app/api/inbox/messages/route.test.ts && npx tsc --noEmit`

## Slice 6a — Insert-first ingest and bot-facing ordering

Spec: `media-ingest` → "Insert first, process media after", "Ready or failed transition", "Bot-facing dispatch only after media settles", "Originals are never re-encoded"; `inbox-realtime` → "Realtime media resolves without reload" (rows become pending only from here).

- [ ] **T6a.1** RED — ordering proof (ADR-8 tests 1-5). Requirement: `media-ingest` → "Bot-facing dispatch only after media settles", "Insert first, process media after".
  - Goal: add an ordered global `calls` log to the existing fake builder and write: image success (insert `pending` + proxy `media_url`; first `ready` update index below every bot-facing call; `message.received` exactly once); image failing twice (`failed` before every bot-facing call; `media_url` never changes); the parameterised invariant over `image, video, document, audio, sticker` (at invocation time the row is `ready` or `failed`); text (no `media_status`, tail runs); duplicate wamid (nothing inserted, nothing dispatched).
  - Files: `src/app/api/whatsapp/webhook/route.test.ts`
  - Test: itself.
  - Verify: `npx vitest run src/app/api/whatsapp/webhook/route.test.ts` — new cases FAIL.

- [ ] **T6a.2** RED — settlement module. Requirement: `media-ingest` → "Ready or failed transition", "Unrecoverable failure becomes failed".
  - Goal: failing tests for the 10 s/25 s/20 s timeouts aborting, one retry with 1 s backoff, the 16 MiB cap producing `failed`, and every update carrying the `AND media_status='pending'` guard.
  - Files: `src/lib/whatsapp/inbound-media.test.ts` (new)
  - Test: itself.
  - Verify: `npx vitest run src/lib/whatsapp/inbound-media.test.ts` — FAIL.

- [ ] **T6a.3** GREEN — abortable Meta calls. Requirement: `media-ingest` → "Insert first, process media after".
  - Goal: add an optional `signal` to `getMediaUrl` and `downloadMedia` without changing existing callers.
  - Files: `src/lib/whatsapp/meta-api.ts`
  - Test: `src/lib/whatsapp/meta-api.test.ts`, `src/lib/whatsapp/meta-api.media.test.ts`, `src/lib/whatsapp/meta-api.resumable.test.ts` (existing, must stay green)
  - Verify: `npx vitest run src/lib/whatsapp/meta-api.test.ts src/lib/whatsapp/meta-api.media.test.ts src/lib/whatsapp/meta-api.resumable.test.ts`

- [ ] **T6a.4** GREEN — extract the tail verbatim. Requirement: `media-ingest` → "Bot-facing dispatch only after media settles"; `chat-media-delivery` → "Existing media_url readers are unaffected".
  - Goal: move `dispatchInboundToFlows` → `runAutomationsForTrigger` → `dispatchInboundToAiReply` → `dispatchEventDurably('message.received')` into `runInboundTail(args)` in the same order and content; no behaviour change yet.
  - Files: `src/lib/whatsapp/inbound-tail.ts` (new), `src/app/api/whatsapp/webhook/route.ts`
  - Test: `src/app/api/whatsapp/webhook/route.test.ts` (existing non-media cases must stay green)
  - Verify: `npx vitest run src/app/api/whatsapp/webhook/route.test.ts`

- [ ] **T6a.5** GREEN — `settleInboundMedia`. Requirement: `media-ingest` → "Ready or failed transition", "Thumbnail failure does not lose the message", "Unrecoverable failure becomes failed".
  - Goal: implement ADR-7 step 7: download, 16 MiB check, original upload at today's path, thumbnail for images and stickers with `upsert: true`, one retry with backoff, then the guarded `ready` update (thumbnail failure is non-fatal, reason in `media_error`) or the `failed` update that leaves `media_url` byte-identical to the legacy proxy value.
  - Files: `src/lib/whatsapp/inbound-media.ts` (new)
  - Test: `src/lib/whatsapp/inbound-media.test.ts`
  - Verify: `npx vitest run src/lib/whatsapp/inbound-media.test.ts`

- [ ] **T6a.6** GREEN — reorder the webhook and add the dedupe guard. Requirement: `media-ingest` → "Insert first, process media after", "Duplicate delivery inserts once", "Media update is idempotent per message", "Bot-facing dispatch only after media settles".
  - Goal: implement ADR-7 steps 2-8 exactly: `parseMessageContent` stops downloading and returns `mediaRef` with the proxy placeholder; the pre-insert dedupe query on `(conversation_id, message_id, sender_type='customer')` returns early with `[webhook] duplicate wamid skipped`; insert with `media_status: 'pending'`, proxy `media_url`, `media_claimed_at`, `media_attempts: 1`, then `.select('id').single()`; conversation UPDATE, invite callback and broadcast-reply flag after the insert; `settleInboundMedia`; then `runInboundTail` strictly after it settles. Non-media messages call the tail directly after step 6, unchanged.
  - Files: `src/app/api/whatsapp/webhook/route.ts`
  - Test: `src/app/api/whatsapp/webhook/route.test.ts`
  - Verify: `npx vitest run src/app/api/whatsapp/webhook/route.test.ts`

- [ ] **T6a.7** Staging check with a PRUEBA image.
  - Goal: per `.claude/skills/wacrm-probar-staging/SKILL.md` (read-only), with `ai_autoreply_disabled = true` and never running the Cerebro workflow: the panel shows the message as pending before the file exists, then `ready`; the DB shows the expected column values.
  - Files: none.
  - Test: manual + read-only SQL.
  - Verify: record the observed transition and the DB row in the PR.

- [ ] **T6a.8** Verification.
  - Goal: suite and `tsc`; confirm `processMessage` still returns `{ guardado: true }` so `whatsapp_webhook_log.procesado` and the ingest watchdog keep their meaning.
  - Files: none.
  - Test: slice-6a files.
  - Verify: `npx vitest run src/app/api/whatsapp/webhook/route.test.ts src/lib/whatsapp/inbound-media.test.ts src/lib/whatsapp/meta-api.test.ts src/lib/whatsapp/meta-api.media.test.ts && npx tsc --noEmit`

## Slice 6b — Sweeper for stale pending rows

Spec: `media-ingest` → "Sweeper settles stale pending rows" (all three scenarios); `inbox-realtime` → "Realtime media resolves without reload" (the transition the UI observes).

- [ ] **T6b.1** RED — sweeper. Requirement: `media-ingest` → "Stale pending row is retried and settles ready", "Expired media id settles failed", "Sweeper is safe to re-run".
  - Goal: failing tests that `reintentar` rows settle before the tail runs, `fallida` rows run the tail only, rows older than 24 h settle without a tail, the budget stops the loop, and a second run changes nothing.
  - Files: `src/lib/whatsapp/media-sweeper.test.ts` (new)
  - Test: itself.
  - Verify: `npx vitest run src/lib/whatsapp/media-sweeper.test.ts` — FAIL.

- [ ] **T6b.2** RED — cron wiring. Requirement: `media-ingest` → "Sweeper settles stale pending rows".
  - Goal: failing tests that the sweeper is called **after** `flushWebhookOutbox`, that an unauthorized secret runs neither, and that the JSON gains `media: { retried, settledReady, settledFailed, dispatched, skippedStale }`.
  - Files: `src/app/api/cron/webhook-outbox/route.test.ts`
  - Test: itself.
  - Verify: `npx vitest run src/app/api/cron/webhook-outbox/route.test.ts` — new cases FAIL.

- [ ] **T6b.3** GREEN — `sweepPendingMedia`. Requirement: `media-ingest` → "Sweeper settles stale pending rows".
  - Goal: implement ADR-7's sweeper: `rpc('crm_media_reclamar', { p_limit: 5 })`, parse the media id from `media_url`, resolve the account token via `conversations.account_id` and `whatsapp_config`, settle `reintentar`, run the tail only when `created_at > now() - 24 h` with the documented rebuilt arguments, and stop at `budgetMs`.
  - Files: `src/lib/whatsapp/media-sweeper.ts` (new)
  - Test: `src/lib/whatsapp/media-sweeper.test.ts`
  - Verify: `npx vitest run src/lib/whatsapp/media-sweeper.test.ts`

- [ ] **T6b.4** GREEN — call it from the existing worker. Requirement: `media-ingest` → "Sweeper settles stale pending rows".
  - Goal: call the sweeper after the flush in `/api/cron/webhook-outbox`; add no new cron job, route or secret.
  - Files: `src/app/api/cron/webhook-outbox/route.ts`
  - Test: `src/app/api/cron/webhook-outbox/route.test.ts`
  - Verify: `npx vitest run src/app/api/cron/webhook-outbox/route.test.ts`

- [ ] **T6b.5** Verification and staging check.
  - Goal: suite and `tsc`; on staging force a stale `pending` row by SQL, invoke the cron route, and confirm settlement and no duplicate row. Record that a 6a rollback requires keeping 6b deployed or running the sweeper once.
  - Files: none.
  - Test: slice-6b files.
  - Verify: `npx vitest run src/lib/whatsapp/media-sweeper.test.ts src/app/api/cron/webhook-outbox/route.test.ts && npx tsc --noEmit`

## Slice 7 — History backfill (retained 90 days only)

Spec: `media-ingest` → "History backfill" (all three scenarios); `chat-media-delivery` → "Original bytes are unchanged".

- [ ] **T7.1** RED — backfill core. Requirement: `media-ingest` → "History backfill".
  - Goal: failing tests for the keyset selection resuming, the dry run writing nothing while its counters equal the real run on the same fixture, a missing object producing `failed`, legacy `/api/whatsapp/media/` rows counted and untouched, and non-images never downloaded.
  - Files: `src/lib/storage/media-backfill.test.ts` (new)
  - Test: itself.
  - Verify: `npx vitest run src/lib/storage/media-backfill.test.ts` — FAIL.

- [ ] **T7.2** GREEN — `planBatch`, `processRow`, `summarise`. Requirement: `media-ingest` → "History backfill", "Originals are never re-encoded".
  - Goal: implement ADR-9: relative imports only with injected `db` and `storage`; selection on `media_status IS NULL` plus a chat-media `media_url`, ordered `(created_at, id)`; per-account paged `storage.list`; download only images and stickers; `upsert: true` thumbnails; the four per-row outcomes; the counters `would_ready_with_thumb`, `would_ready_no_thumb`, `would_fail_missing`, `legacy_meta`.
  - Files: `src/lib/storage/media-backfill.ts` (new)
  - Test: `src/lib/storage/media-backfill.test.ts`
  - Verify: `npx vitest run src/lib/storage/media-backfill.test.ts`

- [ ] **T7.3** GREEN — CLI runner. Requirement: `media-ingest` → "History backfill" (batched, resumable, dry-run).
  - Goal: implement `infra/media/backfill-media.mts` with `--dry-run`, `--batch`, `--sleep-ms`, `--limit`, `--after`, `--env`; read credentials from the env file only and never print them; confirm the host Node is ≥ 22.6 before `--experimental-strip-types`.
  - Files: `infra/media/backfill-media.mts` (new)
  - Test: `src/lib/storage/media-backfill.test.ts` (core) + a dry run against staging.
  - Verify: `node --version` ≥ 22.6, then a staging `--dry-run`.

- [ ] **T7.4** GATE — storage quota headroom. Requirement: `media-ingest` → "History backfill"; design open question on the Free-plan 1 GB cap.
  - Goal: check current Storage usage (875 MB on 2026-11-27) against the 1 GB Free-plan file-storage limit plus the 45-72 MB thumbnail estimate, and either confirm headroom or stop and report that the backfill cannot run in production yet (plan change or retention-first ordering is an owner decision).
  - Files: none.
  - Test: none.
  - Verify: the measured usage and the headroom decision are recorded in the PR and in `openspec/changes/inbox-media-performance/measurements.md`.

- [ ] **T7.5** Staging dry run then real run. Requirement: `media-ingest` → "Dry run matches the real run", "Backfill covers every historical image".
  - Goal: dry run, then the real run on staging; compare the counters; spot-check that every retained image has a thumbnail or a recorded reason, and that originals are unchanged.
  - Files: none.
  - Test: manual + read-only SQL.
  - Verify: counters match or every difference is explained; recorded in the PR.

- [ ] **T7.6** GATE — production backfill approval and window (G1 + T7.4 outcome). Requirement: `media-ingest` → "History backfill" ("production only with the owner's go-ahead").
  - Goal: present the owner the staging numbers, the estimated reads (images only, well under 875 MB), the 45-72 MB growth and the proposed off-peak window; wait for explicit approval of the run and the window.
  - Files: none.
  - Test: none.
  - Verify: the approval and the window are recorded in the change.

- [ ] **T7.7** GATE-blocked — production dry run then real run in the approved window.
  - Goal: production dry run, compare with the staging shape, then the real run in the window, batched with `--sleep-ms` and resumable; report the final counters and any resume events.
  - Files: none.
  - Test: none.
  - Verify: production counters recorded; any unexplained difference stops the run.

## Measurement 3 — after 5b + 7

- [ ] **TM3** Final measurement of the read budget. Requirement: `chat-media-delivery` → "First-page media weight"; `inbox-thread-read` → "First-page performance budget", "Measurement record".
  - Goal: same baseline method; record time to first signed media, first-page media bytes (target under 1.5 MB, baseline 5.3 MB), proxy request count (target 0), and the pre-fetch latency after. Criteria not measured are reported unmeasured.
  - Files: `openspec/changes/inbox-media-performance/measurements.md`
  - Test: none.
  - Verify: numbers with a date, and each success criterion marked met / not met / unmeasured.

## Slice 8 — 90-day retention and unavailable-media rendering

Spec gap: **no requirement in the four delta specs covers retention or purged media.** The only partly applicable requirement is `chat-media-delivery` → "Pending and failed media states are visible". T8.1 must close this gap before any code.

- [x] **T8.1** GATE — spec coverage for retention. RESOLVED 2026-11-27: new capability spec `specs/chat-media-retention/spec.md` (12 requirements, 31 scenarios) plus `design-retention.md` (decisions D-R1..D-R8). Slice 8 may proceed.
  - Goal: return the retention decision (90 days, delete objects and thumbnails by age, keep `media_url` and all message rows, panel shows unavailable) to `sdd-spec` so it lands as an explicit requirement plus scenarios in `chat-media-delivery` (or a new capability), or record the owner's explicit acceptance of the proposal's Scope wording as the authority. Do not implement slice 8 while the coverage is missing.
  - Files: `openspec/changes/inbox-media-performance/specs/` (via a spec phase, not by apply) — treat these as (read-only) from this phase.
  - Test: none.
  - Verify: the new requirement text exists in the change specs before T8.4 starts.

- [ ] **T8.2** RED — retention core. Requirement: resolved by T8.1.
  - Goal: failing tests for the 90-day age filter (deletion by object age, never by conversation), the per-run deletion cap, dry-run and real counts matching on the same fixture, thumbnails deleted together with their original, rows and `media_url` never touched, non-chat-media objects never selected, and batch/rate-limit behaviour.
  - Files: `src/lib/storage/media-retention.test.ts` (new)
  - Test: itself.
  - Verify: `npx vitest run src/lib/storage/media-retention.test.ts` — FAIL.

- [ ] **T8.3** RED — purged media renders as unavailable. Requirement: `chat-media-delivery` → "Pending and failed media states are visible" (closest applicable; a purged object is a third state).
  - Goal: failing test that an object that errors twice (after the single re-sign) renders the existing `MediaUnavailable` state — never a broken image element and never an infinite spinner — for image, video and audio.
  - Files: `src/components/inbox/message-bubble.test.tsx`
  - Test: itself.
  - Verify: `npx vitest run src/components/inbox/message-bubble.test.tsx` — FAIL.

- [ ] **T8.4** GREEN — retention core. Requirement: resolved by T8.1.
  - Goal: implement the core with injected `storage` and `db`: list per account prefix in pages, select by `created_at` older than the window, delete the original and its `thumbs/<base>.webp` sibling, honour the per-run cap, and return `{ scanned, deleted, deletedThumbs, capped, wouldDelete }` for the dry run. Never delete message rows.
  - Files: `src/lib/storage/media-retention.ts` (new)
  - Test: `src/lib/storage/media-retention.test.ts`
  - Verify: `npx vitest run src/lib/storage/media-retention.test.ts`

- [ ] **T8.5** GREEN — CLI runner with a dry run. Requirement: resolved by T8.1.
  - Goal: implement `infra/media/retention-media.mts` with `--dry-run`, `--older-than-days 90`, `--batch`, `--cap`, `--sleep-ms`, `--env`; never print credentials.
  - Files: `infra/media/retention-media.mts` (new)
  - Test: `src/lib/storage/media-retention.test.ts` (core) + a staging dry run.
  - Verify: a staging `--dry-run` reports the object count it would delete and deletes nothing.

- [ ] **T8.6** GREEN — the cron worker runs a capped retention pass. Requirement: resolved by T8.1.
  - Goal: call the retention core from `/api/cron/webhook-outbox` **after** the sweeper, batched and rate-limited with the per-run cap, and extend the worker JSON with a `retention` field. Deletion must be safe to re-run.
  - Files: `src/app/api/cron/webhook-outbox/route.ts`
  - Test: `src/app/api/cron/webhook-outbox/route.test.ts` (extend)
  - Verify: `npx vitest run src/app/api/cron/webhook-outbox/route.test.ts`

- [ ] **T8.7** GREEN — unavailable state in the bubble. Requirement: `chat-media-delivery` → "Pending and failed media states are visible".
  - Goal: after one failed re-sign, render the existing `MediaUnavailable` component for every media type; reuse its current copy so no new Spanish string is invented.
  - Files: `src/components/inbox/message-bubble.tsx`
  - Test: `src/components/inbox/message-bubble.test.tsx`
  - Verify: `npx vitest run src/components/inbox/message-bubble.test.tsx`

- [ ] **T8.8** GATE — enabling deletion in production. Requirement: resolved by T8.1.
  - Goal: present the owner the staging dry-run object count and total bytes (steady state target under 700 MB) and get explicit approval before the production deploy that starts deleting. Deletion is irreversible; do not enable it on a previous approval.
  - Files: none.
  - Test: none.
  - Verify: the approval and the dry-run numbers are recorded in the change.

- [ ] **T8.9** Verification and staging check.
  - Goal: suite and `tsc`; on staging verify the dry-run count equals the real-run count, and that a purged conversation renders media as unavailable with no broken element and no spinner.
  - Files: none.
  - Test: slice-8 files.
  - Verify: `npx vitest run src/lib/storage/media-retention.test.ts src/components/inbox/message-bubble.test.tsx src/app/api/cron/webhook-outbox/route.test.ts && npx tsc --noEmit`

---

## Blocking owner gates (summary)

| Gate | Task | Blocks | Owner answer needed |
|---|---|---|---|
| G1 Backfill run + window | T7.6 | T7.7 | Approve the production run, its window and the 45-72 MB growth |
| G2 Spanish copy | T5b.10 | pending and failed strings | Confirm "Descargando archivo…" / "No se pudo descargar el archivo" |
| G3 Production measurement | TM1, TM2, TM3 | production numbers | Approve opening the heaviest real conversation (it may change its unread state) |
| G4 Migration 400 go-ahead | T5a.6 | T5a.7 | Explicit per-apply approval after `previa` |
| G5 Slice order | T5a.2 | all schema work | Confirm slices 1-4 shipped and measured in production |
| G6 Storage quota headroom | T7.4 | T7.6, T8.8 | Confirm headroom under the 1 GB Free-plan cap, or decide a plan change |
| G7 Retention enablement | T8.8 | production deploy of slice 8 | Approve irreversible deletion after seeing the dry-run counts |
| G8 Retention spec coverage | T8.1 | all of slice 8 | Route to `sdd-spec` or accept the proposal Scope as authority |
| G9 Slice 4b decision | T4b.1 | T4b.2..n | Accept "not needed" with evidence, or approve a newly sized slice |

## Completion criteria per slice

Every slice PR closes only when: its named tests are green, `npx tsc --noEmit` is clean, the slice's runtime harness line has an observed result (or an explicit "not run" reason), and the slice's own rollback boundary is stated in the PR.

## Delivery decisions (owner, 2026-11-27)

- **PR target:** `feat/port-chat-operations-calculator`, never `master` (master is 1,751 commits behind and lacks the chat-media modules).
- **Size policy:** `size:exception` accepted for slices that exceed the 400-line budget as one cohesive unit. Observed: slice 1 = 1,191 authored lines, slice 2 = ~578. Splitting was rejected because required test surface would be separated from the implementation it proves.
- **Base:** `feat/inbox-media-performance` branched from `275bec1b`.
