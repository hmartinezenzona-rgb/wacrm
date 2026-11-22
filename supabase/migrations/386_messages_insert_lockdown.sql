-- 386_messages_insert_lockdown.sql
--
-- Production and staging still carry the permissive policy
-- "Service role can insert messages" (cmd INSERT, roles PUBLIC, WITH CHECK true).
-- Combined with the default GRANT INSERT to anon, anyone holding the public anon
-- key can insert rows into public.messages for any known conversation id.
--
-- Repo migration 017 already drops this policy and relies on service_role's
-- BYPASSRLS for webhook inserts, but the live databases were migrated from a 017
-- file that predates that DROP.
--
-- This migration restores the intended state:
--   1. drops the permissive INSERT policy (service_role bypasses RLS anyway),
--   2. revokes write privileges on public.messages from anon,
--   3. leaves authenticated INSERT governed by messages_modify (account membership).
--
-- Guarded by supabase/staging/assertions/messages-insert-lockdown.sql.

DROP POLICY IF EXISTS "Service role can insert messages" ON public.messages;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.messages FROM anon;
