-- ROLLBACK-386-messages-insert-lockdown.sql
--
-- Restores the exact pre-386 state, including the permissive policy, so the
-- rollback is faithful. Rolling back re-opens the anonymous insert hole: only
-- use it to undo 386 immediately after applying it.

GRANT INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.messages TO anon;

DROP POLICY IF EXISTS "Service role can insert messages" ON public.messages;
CREATE POLICY "Service role can insert messages" ON public.messages
  FOR INSERT WITH CHECK (true);
