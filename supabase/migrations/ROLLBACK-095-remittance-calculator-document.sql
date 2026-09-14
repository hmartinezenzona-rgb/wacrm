-- ROLLBACK for 095_remittance_calculator_document.sql.
--
-- WARNING: this is a genuinely destructive rollback (095 creates new
-- tables, not new versions of existing functions), and both tables can
-- hold real data an admin entered through /calculadora — including, on a
-- database that already ran the real hermes release, the exact rows the
-- user's weekly close depends on. DO NOT run this against any database
-- that has calculator data you still need. It exists for reverting an
-- environment where 095 was applied by mistake with no real usage yet.
--
-- Drops only what 095 added, in dependency order. Every statement is
-- IF EXISTS, so this is safe to re-run.

DROP TRIGGER IF EXISTS remittance_calculator_entries_append_only ON public.remittance_calculator_entries;
DROP FUNCTION IF EXISTS public.remittance_calculator_entries_lock_completed();

DROP TABLE IF EXISTS public.remittance_calculator_entries;
DROP TABLE IF EXISTS public.remittance_calculator_documents;

-- pgcrypto is left in place: other objects in this database may depend on
-- gen_random_uuid()/gen_random_bytes(), and DROP EXTENSION here could take
-- down unrelated functionality this migration never owned.
