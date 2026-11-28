# Bot ownership indicator + filter (Slice A of the conversation-list.tsx port)

## Objective
Port production's "who owns this conversation right now" feature (bot/human/paused, with an icon in the row and a filter) into the tracker, without the higher-risk selection/pin remerge (that's Slice B, deferred).

## Why
User saw a bot-paused icon + filter in production's conversation list that this repo lacks. Investigation (2026-09-24) found it's a well-factored, self-contained feature: `conversation-ownership.ts` (pure resolver) + `ownership-icon.tsx` (presentational) + filter pills + an agent-name lookup, plus a write-path piece (`pause-ai-on-agent-send.ts`) needed so the "human replied manually without being assigned" case can actually trigger.

Corrected a real error in the investigation before starting: it claimed `ai_handoff_reason`/`ai_handoff_at` don't exist in our schema because no migration file creates them. Verified directly against staging's live DB — **the columns already exist for real** (applied out-of-band at some point; the migration FILE, numbered 093 in production's lineage, was just never committed to this repo). No new columns needed, only a migration file to close the documentation gap.

## Scope — Slice A only
1. `src/lib/inbox/conversation-ownership.ts` + `.test.ts` — verbatim port from `83422d90bbfa1acff9c79be496596f549fdb8c26`.
2. `src/components/inbox/ownership-icon.tsx` — verbatim port.
3. `src/lib/inbox/pause-ai-on-agent-send.ts` + `.test.ts` — verbatim port from commit `47d9ccc` (that commit bundles 4 unrelated changes — 3A/3B/3C/3F — only 3A, this file, is in scope).
4. Surgical addition to `src/app/api/whatsapp/send/route.ts`: import + call `pauseAiOnAgentSend(supabase, conversationId)` after a successful send. Does NOT include 3C's `senderId`/`sender_id` attribution — out of scope, not requested.
5. `src/components/inbox/conversation-list.tsx`: ADD the ownership import, `FILTROS_PROPIEDAD` + `filtroPropiedad` state + pill filter UI + filtering logic + `nombresPorAgente` lookup + render `<OwnershipIcon>` per row — merged carefully alongside the existing PR#36 batch-selection/pin code (which stays exactly as-is). Not a file overwrite.
6. New migration `115_...ai_handoff_columns...sql` (+ROLLBACK): `ADD COLUMN IF NOT EXISTS` for `ai_handoff_reason`/`ai_handoff_at` on `conversations` — documents/registers columns that already exist live, closes the missing-migration-093 gap. Idempotent, safe no-op on staging (already has the columns).

## Explicitly OUT of scope
- 3B (`ai_generated` in API v1), 3C (`sender_id` forward-fill / `senderId` param on `sendMessageToConversation`), 3F (deal-detail remittance-summary panel — pipelines-related, moot since pipelines UI is deleted).
- Slice B: the batch-selection/pin rewrite in `conversation-list.tsx` — production independently rebuilt the same feature PR#36 added, incompatible internals, needs its own careful re-merge as separate follow-up work. Do not touch `selectedIds`/`toggleSelect`/`handleBatchArchive`/the pin button/the prefetch-on-hover code in this slice.

## Status
Done — delegated implementation, 2026-09-23, branch `feat/inbox-bot-ownership-indicator`
(off `feat/port-chat-operations-calculator` @ `da03315`). All 6 scope items shipped in
3 work-unit commits:
  1. `cd50134` — steps 1-2: verbatim port of `conversation-ownership.ts`(+test),
     `ownership-icon.tsx`, `pause-ai-on-agent-send.ts`(+test); surgical wire-in to
     `src/app/api/whatsapp/send/route.ts` (import + `pauseAiOnAgentSend(supabase,
     conversationId)` after successful send). `senderId`/3C explicitly NOT added;
     `send-message.ts` untouched (confirmed via diff).
  2. `fe5ed45` — step 3: merged ownership filter pills, `filtroPropiedad` state,
     `nombresPorAgente` lookup, and `<OwnershipIcon>` render into
     `conversation-list.tsx` alongside (not replacing) the existing batch-
     selection/pin/prefetch code, which is untouched (diff-verified).
  3. `f890bd2` — step 4: migration `115_register_ai_handoff_columns.sql` +
     ROLLBACK. Applied to staging via
     `docker run --rm -i --env-file .env.staging postgres:16-alpine sh -c
     'psql "$CRM_STAGING_DATABASE_URL" -f -'` (note: `-i` flag required for
     stdin piping to work — plain `docker run` without `-i` silently no-ops).
     Confirmed no-op: `SELECT column_name FROM information_schema.columns
     WHERE table_name='conversations' AND column_name LIKE 'ai_handoff%'`
     returned the same 3 rows (`ai_handoff_at`, `ai_handoff_reason`,
     `ai_handoff_summary`) before and after.

Verification (final, full suite):
  - `npx tsc --noEmit -p .` — 0 errors.
  - `npm run lint` — 0 errors, 45 warnings (identical to baseline; confirmed by
    lint on a temporarily-stashed clean tree — none of the 45 are new).
  - `npm test` — 123/124 files, 1418/1420 tests pass. The only 2 failures are the
    documented pre-existing `src/lib/dashboard/date-utils.test.ts` frozen-clock
    failures (`mondayIndex` — unrelated to this feature).

Judgment calls: none deviated from instructions. `nombresPorAgente` state and the
profiles-loading effect were placed matching production's relative ordering
(after `filter`/`filtroPropiedad` state, before the fetch-conversations effect)
since the branch had no equivalent to anchor against.

Out of scope, confirmed untouched: `src/lib/api/v1/conversations.ts`, any
`sender_id`/`senderId` forward-fill, `src/components/pipelines/**`,
`selectedIds`/batch-selection/pin/prefetch logic in `conversation-list.tsx`.
No PR opened, production untouched, per instructions.
