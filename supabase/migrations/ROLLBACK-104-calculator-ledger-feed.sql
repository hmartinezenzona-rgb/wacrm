-- =====================================================================
-- ROLLBACK-104 — reverts 104_calculator_ledger_feed.sql
--
-- Drops the feed trigger and its helpers, restores 095's stricter
-- append-only guard and status vocabulary, and removes the columns and
-- the feed-start marker this migration added.
--
-- DESTRUCTIVE in three places, all unavoidable if 095's constraints are
-- to hold again:
--   1. Voided entries have a status 095 does not know. They are deleted.
--      An entry is voided only when a human reverted the operation, so
--      what is lost is the record that the reversal happened — the
--      operation's own history still shows it.
--   2. `calculator_feed_failed` / `calculator_pending_resolved` audit rows
--      would violate the restored action CHECK. They are deleted.
--   3. The rate snapshot columns (usdt_buy_gyd, usdt_sell_gyd,
--      rate_version_id, missing_inputs, delivery_mode) are dropped, so
--      surviving entries keep only the two rates 095 defined.
--
-- Run this BEFORE ROLLBACK-103: this migration's rate_version_id foreign
-- key points at calculator_rate_versions.
-- =====================================================================

DROP TRIGGER IF EXISTS zzz_remittance_operations_calculator_feed ON remittance_operations;
DROP FUNCTION IF EXISTS remittance_operations_calculator_feed();

DROP VIEW IF EXISTS calculator_unfed_operations;

DROP FUNCTION IF EXISTS crm_feed_calculator(uuid);
DROP FUNCTION IF EXISTS calculator_feed_operation(uuid);
DROP FUNCTION IF EXISTS calculator_missing_rates(text, calculator_rate_versions);
DROP FUNCTION IF EXISTS calculator_service_for_operation(text);

DELETE FROM remittance_admin_audit
 WHERE action IN ('calculator_feed_failed', 'calculator_pending_resolved');

ALTER TABLE remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit
  ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action IN (
    'automation_write_suppressed',
    'automation_completion_suppressed',
    'automation_revert_suppressed',
    'human_correction',
    'human_reassignment',
    'human_deposit_verification',
    'human_forced_verification',
    'human_delivery'
  ));

-- Restore 095's guard: no UPDATE or DELETE of a completed row at all.
CREATE OR REPLACE FUNCTION remittance_calculator_entries_lock_completed()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF OLD.status = 'completed' THEN
    RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- Voided rows must go before the status CHECK is narrowed again. The
-- trigger above would refuse to delete a `completed` row, but a `void`
-- one is not completed, so this passes.
DELETE FROM remittance_calculator_entries WHERE status = 'void';

ALTER TABLE remittance_calculator_entries DROP CONSTRAINT IF EXISTS remittance_calculator_entries_void_shape_chk;
ALTER TABLE remittance_calculator_entries DROP CONSTRAINT IF EXISTS remittance_calculator_entries_usdt_buy_gyd_chk;
ALTER TABLE remittance_calculator_entries DROP CONSTRAINT IF EXISTS remittance_calculator_entries_usdt_sell_gyd_chk;

ALTER TABLE remittance_calculator_entries DROP CONSTRAINT IF EXISTS remittance_calculator_entries_status_chk;
ALTER TABLE remittance_calculator_entries
  ADD CONSTRAINT remittance_calculator_entries_status_chk
  CHECK (status IN ('completed', 'verified_pending'));

ALTER TABLE remittance_calculator_entries
  DROP COLUMN IF EXISTS rate_version_id,
  DROP COLUMN IF EXISTS usdt_buy_gyd,
  DROP COLUMN IF EXISTS usdt_sell_gyd,
  DROP COLUMN IF EXISTS missing_inputs,
  DROP COLUMN IF EXISTS delivery_mode,
  DROP COLUMN IF EXISTS voided_at,
  DROP COLUMN IF EXISTS void_reason;

DROP TABLE IF EXISTS calculator_feed_state;
