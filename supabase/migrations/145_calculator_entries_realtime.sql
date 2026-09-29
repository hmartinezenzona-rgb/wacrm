-- =====================================================================
-- 145 — remittance_calculator_entries joins supabase_realtime
--
-- PROBLEM (B4.2, production feedback 2026-09-29): "The calculator updates
-- in real time when a remesa completes, with no page refresh." Today it
-- doesn't: the calculadora page (`src/app/(dashboard)/calculadora/page.tsx`)
-- fetches its "Operaciones del chat" rows exactly once, on mount, from
-- `GET /api/calculadora` — no realtime subscription, no polling. A remesa
-- completed (or voided) by another tab/operator while the page is open
-- never appears until a manual reload.
--
-- WHY: `remittance_calculator_entries` was never added to the
-- `supabase_realtime` publication — `104_calculator_ledger_feed.sql`
-- introduced the feed trigger that writes this table but didn't touch the
-- publication, and nothing since has either. Without the table in the
-- publication, no `postgres_changes` subscription on it can ever fire,
-- regardless of RLS.
--
-- FIX: add the table to `supabase_realtime`, same idempotent
-- existence-guarded shape `024_member_presence.sql`/`001_initial_schema.sql`
-- already use for every other realtime-enabled table in this repo. No RLS
-- change needed — `remittance_calculator_entries_select`
-- (`106_calculator_session_client_access.sql`, `is_account_member(account_id)`)
-- already scopes SELECT the same way it scopes the initial `GET
-- /api/calculadora` read, and Realtime enforces that same policy per
-- subscriber. The app-side subscription (`src/hooks/use-calculator-entries-
-- realtime.ts`, wired into the calculadora page) is unfiltered, the same
-- posture `src/hooks/use-realtime.ts` already uses for `messages`/
-- `conversations`.
--
-- Guarded by supabase/staging/assertions/calculator-entries-realtime.sql.
--
-- ROLLBACK: ROLLBACK-145-calculator-entries-realtime.sql
-- =====================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'remittance_calculator_entries'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE remittance_calculator_entries;
  END IF;
END $$;

-- =====================================================================
-- VALIDATE ON STAGING — see
-- supabase/staging/assertions/calculator-entries-realtime.sql.
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-145-calculator-entries-realtime.sql
-- =====================================================================
