-- =====================================================================
-- 171 — remittance_operations joins supabase_realtime
--
-- (Sliced as "170" in odd/tasks/eliminate-deals.md; renumbered to 171
-- because the split-deposit-minimums work landed migration 170 on this
-- branch in the same session. Content is unchanged — this is the same
-- unit, at the next free number.)
--
-- PROBLEM (Phase 6.5): the operations panel kept its live refresh by
-- subscribing to Supabase Realtime on the `deals` table
-- (`src/components/inbox/operations/operations-panel-container.tsx`). That
-- was always an indirect proxy — `deals` is in the `supabase_realtime`
-- publication, the remittance tables are not — and the proxy is now dead.
-- `deals` is written today by exactly three functions:
-- `cerebro_aplicar_nombre_confirmado` (via the `trg_nombre_confirmado_zelle`
-- trigger on `messages`), plus the panel's own `crm_verificar_deposito` and
-- `crm_forzar_verificacion` RPCs. No trigger on `remittance_operations` or
-- its children writes `deals`, and no bot-path function does either. So the
-- bot's operation changes have not reached the panel since the flow moved
-- onto `remittance_operations` — and nothing announced that: the panel
-- simply never refreshed, with no error.
--
-- WHY: `remittance_operations` was never added to the `supabase_realtime`
-- publication, so no `postgres_changes` subscription on it can ever fire,
-- regardless of RLS. A correct `src/` subscription against an unpublished
-- table is a silent no-op — exactly the failure mode this migration
-- removes.
--
-- FIX: add the table to `supabase_realtime`, same idempotent
-- existence-guarded shape `024_member_presence.sql`/`001_initial_schema.sql`
-- already use for every other realtime-enabled table in this repo. No RLS
-- change needed — `remittance_operations_select` is
-- `is_account_member(account_id)`, tenant-scoped, and Realtime enforces that
-- same policy per subscriber, so publishing creates no cross-tenant
-- exposure. The app-side subscription keeps its `conversation_id=eq.<id>`
-- filter unchanged: `remittance_operations` has `conversation_id`.
--
-- `REPLICA IDENTITY FULL` is deliberately NOT set here: `deals` is
-- `relreplident='d'` today, so DELETE-event behaviour is unchanged by this
-- migration. Carried as a follow-up, not an oversight.
--
-- Guarded by supabase/staging/assertions/operations-realtime.sql.
--
-- ROLLBACK: ROLLBACK-171-operations-realtime-publication.sql
-- =====================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'remittance_operations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE remittance_operations;
  END IF;
END $$;

-- =====================================================================
-- VALIDATE ON STAGING — see
-- supabase/staging/assertions/operations-realtime.sql.
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-171-operations-realtime-publication.sql
-- =====================================================================
