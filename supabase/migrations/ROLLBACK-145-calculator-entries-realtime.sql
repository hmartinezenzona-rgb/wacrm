-- =====================================================================
-- ROLLBACK 145 — remove remittance_calculator_entries from
--                supabase_realtime
--
-- Reverts the calculadora page's live chat-operations feed to its
-- pre-145 shape (initial load only, no `postgres_changes` events ever
-- fire for this table again). Safe: no data change, no RLS change, and
-- `src/hooks/use-calculator-entries-realtime.ts`'s subscription simply
-- goes quiet (the page still loads and refetches on demand exactly as it
-- did before 145).
-- =====================================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'remittance_calculator_entries'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE remittance_calculator_entries;
  END IF;
END $$;
