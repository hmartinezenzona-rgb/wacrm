-- =====================================================================
-- ROLLBACK-115 — reverts 115_register_ai_handoff_columns.sql
--
-- DANGER — READ BEFORE RUNNING
-- ---------------------------------------------------------------------
-- `ai_handoff_reason` and `ai_handoff_at` already existed live on staging
-- (and, per the source commit's own claim, production) BEFORE 115 was
-- ever applied — 115 only registered them in this repository's migration
-- history, it did not create them. Dropping these columns for real would
-- DESTROY any data already written through them (the bot-ownership
-- indicator's `pauseAiOnAgentSend` writes both on every manual reply).
--
-- This rollback is safe to run ONLY if 115 is being reverted before any
-- real data was written through it in the environment you're running
-- this against (e.g. undoing a from-scratch local build that applied 115
-- and nothing has used the columns yet). On any environment where the
-- ownership feature has been live for even a moment, do NOT run this —
-- reverting the migration FILE registration is not the same as reverting
-- the data, and there is no way to recover a dropped column's contents.
-- =====================================================================

ALTER TABLE conversations
  DROP COLUMN IF EXISTS ai_handoff_reason,
  DROP COLUMN IF EXISTS ai_handoff_at;

NOTIFY pgrst, 'reload schema';
