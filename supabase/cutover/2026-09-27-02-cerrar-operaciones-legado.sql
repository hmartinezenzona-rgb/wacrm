-- =====================================================================
-- Cutover 2026-09-27 — STEP 3b (WRITE): close the legacy open operations.
--
-- RUN BEFORE MIGRATION 104 (the calculator ledger feed). Before 104 the only
-- trigger on remittance_operations is cerebro_op_touch (stamps updated_at,
-- version, completed_at / cancelled_at): nothing is sent to customers and
-- nothing enters the ledger. DEALS ARE NOT TOUCHED on purpose: deals carry
-- the stage-change notification triggers.
--
-- What it does:
--   ready_to_transfer              -> completed  (transferred in the chat, card never moved)
--   every other open status        -> cancelled
--   ids listed in v_keep           -> left open (live customers found in step 3a)
-- A record of every closed operation (with its previous status) is kept in
-- cutover_legacy_ops_2026_09_27, so the change can be audited or undone.
--
-- Edit v_keep if step 3a found live customers, then run the whole file once.
-- =====================================================================
BEGIN;

-- Mark this transaction as an administrator action. Harmless before 096; after
-- 096 the completion guard would otherwise silently revert an automation's
-- 'completed' (seen when testing on staging).
SELECT set_config('wacrm.origin', 'admin', true);

CREATE TABLE cutover_legacy_ops_2026_09_27 (
  operation_id    uuid PRIMARY KEY,
  previous_status text NOT NULL,
  new_status      text NOT NULL,
  deal_id         uuid,
  created_at      timestamptz,
  closed_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE cutover_legacy_ops_2026_09_27 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON cutover_legacy_ops_2026_09_27 FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  -- Live customers to keep open, e.g. ARRAY['00000000-0000-0000-0000-000000000000']::uuid[]
  v_keep uuid[] := ARRAY[]::uuid[];
  v_completed int;
  v_cancelled int;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'calculator_feed_operation') THEN
    RAISE EXCEPTION 'migration 104 is already applied: closing now would feed the ledger. Stop.';
  END IF;

  INSERT INTO cutover_legacy_ops_2026_09_27 (operation_id, previous_status, new_status, deal_id, created_at)
  SELECT o.id, o.status,
         CASE WHEN o.status = 'ready_to_transfer' THEN 'completed' ELSE 'cancelled' END,
         o.deal_id, o.created_at
    FROM remittance_operations o
   WHERE o.status NOT IN ('completed', 'cancelled')
     AND o.id <> ALL (v_keep);

  UPDATE remittance_operations o SET status = 'completed'
    FROM cutover_legacy_ops_2026_09_27 c
   WHERE c.operation_id = o.id AND c.new_status = 'completed';
  GET DIAGNOSTICS v_completed = ROW_COUNT;

  UPDATE remittance_operations o SET status = 'cancelled'
    FROM cutover_legacy_ops_2026_09_27 c
   WHERE c.operation_id = o.id AND c.new_status = 'cancelled';
  GET DIAGNOSTICS v_cancelled = ROW_COUNT;

  -- Never report a change that did not happen: every recorded row must now be
  -- in its new status, or the whole transaction is rolled back.
  IF EXISTS (SELECT 1 FROM cutover_legacy_ops_2026_09_27 c JOIN remittance_operations o ON o.id = c.operation_id
              WHERE o.status <> c.new_status) THEN
    RAISE EXCEPTION 'some operations did not reach their new status; nothing was changed';
  END IF;

  RAISE NOTICE 'closed: % completed, % cancelled, % kept open', v_completed, v_cancelled, cardinality(v_keep);
END $$;

-- Check: only the kept ids (if any) remain open.
SELECT status, count(*) FROM remittance_operations
 WHERE status NOT IN ('completed', 'cancelled') GROUP BY 1;

COMMIT;

-- UNDO (only if needed, before migration 104):
--   UPDATE remittance_operations o SET status = c.previous_status, completed_at = NULL, cancelled_at = NULL
--     FROM cutover_legacy_ops_2026_09_27 c WHERE c.operation_id = o.id;
