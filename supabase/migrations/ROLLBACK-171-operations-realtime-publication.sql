-- =====================================================================
-- ROLLBACK 171 — remove remittance_operations from supabase_realtime
--
-- (Sliced as "170"; renumbered to 171 — see the migration header.)
--
-- Reverts the operations panel's live refresh to its pre-171 shape
-- (initial load only, no `postgres_changes` events ever fire for this table
-- again). Safe: no data change, no RLS change, and
-- `src/components/inbox/operations/operations-panel-container.tsx`'s
-- subscription simply goes quiet (the panel still loads and refetches on
-- demand exactly as it did before 171).
--
-- What reverting costs: the panel's live refresh. For bot activity that
-- refresh is *already* silent before 171 (the bot writes
-- `remittance_operations`, not `deals`), so reverting loses only the human
-- panel-action and Zelle-name-message paths that still write `deals` today.
-- =====================================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'remittance_operations'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE remittance_operations;
  END IF;
END $$;
