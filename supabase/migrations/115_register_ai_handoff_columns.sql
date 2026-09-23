-- =====================================================================
-- 115 — Register `ai_handoff_reason` / `ai_handoff_at` on `conversations`
--
-- SCOPE (ODD change inbox-bot-ownership-indicator, Slice A, task 6). Ports
-- the bot-ownership indicator/filter feature (conversation-ownership.ts +
-- ownership-icon.tsx + pauseAiOnAgentSend) from production's
-- `privado/ui/operations-visibility-v2` branch. This migration is the
-- schema half of that port.
--
-- WHY THIS MIGRATION EXISTS EVEN THOUGH IT CHANGES NOTHING LIVE
-- ---------------------------------------------------------------------
-- `ai_handoff_reason` (text, nullable) and `ai_handoff_at` (timestamptz,
-- nullable) already exist for real on staging's `conversations` table —
-- confirmed directly against staging's live DB via
-- `information_schema.columns` before this migration was authored. They
-- were applied out-of-band at some point and, per the source commit's own
-- claim (production `47d9ccc`, section "3A"), also exist in production.
-- No migration FILE in this repository creates them: the migration that
-- should have (numbered 093 in production's lineage) was never committed
-- here. That is a documentation gap, not a missing column — this
-- migration closes the gap by registering what is already live, using
-- `ADD COLUMN IF NOT EXISTS` so it is a guaranteed no-op everywhere the
-- columns already exist and a real (safe, additive) change only on an
-- environment that somehow doesn't have them yet (e.g. a from-scratch
-- local build).
--
-- WHAT USES THESE COLUMNS
-- ---------------------------------------------------------------------
-- `src/lib/inbox/conversation-ownership.ts` reads `ai_handoff_reason` to
-- distinguish "a person replied manually" (`agent_replied`, still counts
-- as human ownership even with nobody assigned) from an unexplained AI
-- pause. `src/lib/inbox/pause-ai-on-agent-send.ts` writes both columns
-- when a person sends a message from the dashboard.
--
-- `ai_handoff_summary` already existed before this migration and is
-- untouched here — it belongs to a different, already-ported feature.
--
-- ROLLBACK: see ROLLBACK-115-register-ai-handoff-columns.sql. Read its
-- header before running it — dropping these columns for real would
-- destroy live data once anything has written through them.
-- =====================================================================

ALTER TABLE conversations
  ADD COLUMN IF NOT EXISTS ai_handoff_reason text,
  ADD COLUMN IF NOT EXISTS ai_handoff_at timestamptz;

NOTIFY pgrst, 'reload schema';
