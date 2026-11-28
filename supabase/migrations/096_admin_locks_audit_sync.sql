-- 096 — Admin field locks, audit trail, and automation guards 12a/12b
--
-- SCOPE (SDD change port-chat-operations-calculator, Slice 4, tasks 4.1-4.5):
--   1. `remittance_admin_audit` — the durable record of every time this
--      migration's triggers silently suppress or override an automation
--      write. Read-model for the panel's audit view (later slices).
--   2. `remittance_operations.admin_locked_fields` — a per-field lock map
--      ({field: {by, at}}). Once a human corrects a field, it is locked:
--      automation can no longer clobber it (design decision 2, spec
--      "Operator Corrections Survive Automation Writes").
--   3. Guard 12a — `remittance_operations`: without a human actor (agent+),
--      a transition INTO `completed` is kept at OLD.status (INSERT is
--      coerced to `incident`), and a transition OUT OF `completed` is also
--      kept at OLD.status. Automation can never complete a remesa, and can
--      never move a completed remesa to anything else (design decision 12a).
--   4. Guard 12b — `deals` (remesas pipeline only): the same shape, but on
--      `stage_id` against the Entregada stage. Automation can never move a
--      deal into Entregada, and can never move a deal OUT of Entregada
--      (design decision 12b).
--   5. Lock-aware deal->operation sync: no code change to
--      `cerebro_sync_operacion_desde_deal()` (041/043/060) — its UPDATE on
--      `remittance_operations` is a normal row write like any other, so it
--      passes through the new BEFORE trigger on that table like every other
--      writer. A locked field it tries to overwrite is kept at OLD; a
--      status it tries to set is guarded by 12a exactly like a direct
--      write. See "Why no change to the sync trigger" below.
--
-- WHO COUNTS AS "HUMAN" (design decisions 3 and 12)
--
--   `is_account_member(account_id, min_role)` (017:136-167) reads
--   `auth.uid()`, which is NULL for n8n's `postgres` role (connects via
--   Supavisor with no JWT, confirmed in gate-1.2 findings) and for a
--   service-role client (no `sub` claim). It is the real end-user id for a
--   session client — including inside a SECURITY DEFINER trigger, because
--   `auth.uid()` reads a per-session/per-transaction GUC
--   (`request.jwt.claims`), not the function owner's identity. That is
--   also why a human moving a deal card in the pipeline UI (session client,
--   RLS `deals_update` already requires agent+) correctly reads as human
--   all the way down through `cerebro_sync_operacion_desde_deal` into this
--   migration's guard on `remittance_operations`.
--
--   `wacrm.origin` / `wacrm.actor` are separate, explicit session GUCs a
--   trusted maintenance context (a human-run script under `service_role`,
--   which has no JWT and so no `auth.uid()`) can set to assert itself as
--   human origin — `set_config('wacrm.origin', 'admin', true)` — and to
--   name the actor for the audit trail — `set_config('wacrm.actor', ...,
--   true)`. Genuine automation never sets these. This is why "human actor"
--   below is `is_account_member(...) OR wacrm.origin = 'admin'`, not
--   `is_account_member(...)` alone (decision 12's own rejected-alternatives
--   column rejects a `wacrm.origin`-GUC-*only* gate, not one combined with
--   `is_account_member`).
--
-- WHY SUPPRESS, NEVER RAISE (design decision 12, evidence column)
--
--   `cerebro_registrar_deposito` (079:102-118) writes stage + value + notes
--   in ONE UPDATE; a RAISE EXCEPTION here would also lose the deposit data
--   that same statement was recording. Via the deal->operation bridge,
--   `cerebro_sync_operacion_desde_deal`'s own `EXCEPTION WHEN OTHERS`
--   (060:109-111) would swallow a RAISE anyway and leave `deals` and
--   `remittance_operations` diverged. So every guard below keeps NEW at
--   OLD (or coerces it on INSERT), writes exactly one audit row, and
--   RAISE WARNING (never RAISE EXCEPTION — a WARNING does not abort the
--   transaction, matching "silent keep-OLD + audit, never raise").
--
-- WHY NO CHANGE TO THE SYNC TRIGGER
--
--   `cerebro_sync_operacion_desde_deal()` issues a plain
--   `UPDATE remittance_operations SET status=..., quoted_source_amount=...,
--   contact_id=... WHERE deal_id = NEW.id`. Postgres fires every BEFORE
--   trigger on `remittance_operations` for that UPDATE regardless of which
--   function issued it — there is no separate code path to special-case.
--   Making the new BEFORE triggers below fire for EVERY writer, including
--   this one, is what "lock-aware" means here; rewriting the sync
--   function's SQL would only duplicate logic that already applies.
--
-- TRIGGER ORDERING (Postgres fires same-timing triggers in NAME order)
--
--   `remittance_operations`: `trg_admin_field_locks_operations` and
--   `trg_admin_guard_operations_status` both sort before the existing
--   `trg_remittance_operations_touch` (040), so locks/guard run and settle
--   NEW before the touch trigger computes `version`/`completed_at` from it.
--   `deals`: `trg_admin_guard_deals_stage` sorts before the existing
--   `trg_cerrar_deal_entregado` (052), so a suppressed/coerced `stage_id`
--   is what `cerebro_cerrar_deal_entregado()` and the AFTER triggers
--   (`deals_stage_notify`, `trg_sync_operacion_desde_deal`) actually see —
--   no false-positive "remesa_completada" notification for a move this
--   migration blocked.
--
-- IDEMPOTENT: every CREATE is IF NOT EXISTS / OR REPLACE; every DROP
-- TRIGGER is IF EXISTS before CREATE. Safe to re-run.
--
-- ROLLBACK: ROLLBACK-096-admin-locks-audit-sync.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Audit table
-- ---------------------------------------------------------------------
-- One row per suppressed/coerced automation write. `field_name` is NULL
-- for a status/stage-level guard (12a/12b act on the whole row's
-- transition, not a single field). `reason` stays NULL for every action
-- this migration produces — it becomes NOT NULL-by-application-contract
-- once forced-verification and pending-entry resolution ship (later
-- slices extend this table, never replace it).

CREATE TABLE IF NOT EXISTS remittance_admin_audit (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid NOT NULL,
  table_name  text NOT NULL,
  row_id      uuid,
  field_name  text,
  action      text NOT NULL,
  actor       text,
  reason      text,
  before      jsonb,
  after       jsonb,
  -- clock_timestamp(), not now(): now() is frozen at transaction start,
  -- so a caller that suppresses several writes inside one transaction
  -- (exactly what the staging assertions below do, and what a single n8n
  -- execution touching several rows could do too) would get identical
  -- created_at values, breaking any ">= a moment ago" audit query.
  created_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT remittance_admin_audit_action_chk CHECK (action IN (
    'automation_write_suppressed',
    'automation_completion_suppressed',
    'automation_revert_suppressed'
  ))
);

CREATE INDEX IF NOT EXISTS remittance_admin_audit_row_idx
  ON remittance_admin_audit (table_name, row_id, created_at DESC);

CREATE INDEX IF NOT EXISTS remittance_admin_audit_account_idx
  ON remittance_admin_audit (account_id, created_at DESC);

ALTER TABLE remittance_admin_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS remittance_admin_audit_select ON remittance_admin_audit;
CREATE POLICY remittance_admin_audit_select ON remittance_admin_audit
  FOR SELECT USING (is_account_member(account_id));
-- No write policy: every row is inserted by a SECURITY DEFINER trigger
-- function owned by the migration role, which bypasses RLS. No client
-- path writes this table directly.

COMMENT ON TABLE remittance_admin_audit IS
  'Slice 4 (port-chat-operations-calculator). One row per automation write '
  'this migration''s guards silently suppressed or coerced. Extended, never '
  'replaced, by later slices (forced verification, pending-entry '
  'resolution, operator corrections).';


-- ---------------------------------------------------------------------
-- 2. admin_locked_fields on remittance_operations
-- ---------------------------------------------------------------------
-- Decision 2 also names `receipts`; that table does not exist until
-- Slice 7 (its own migration adds the same column there).

ALTER TABLE remittance_operations
  ADD COLUMN IF NOT EXISTS admin_locked_fields jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS remittance_operations_locked_idx
  ON remittance_operations ((admin_locked_fields <> '{}'::jsonb))
  WHERE admin_locked_fields <> '{}'::jsonb;

COMMENT ON COLUMN remittance_operations.admin_locked_fields IS
  'Slice 4. {field_name: {"by": actor, "at": timestamptz}}. Set '
  'automatically by trg_admin_field_locks_operations the first time a '
  'human (agent+, or an explicit wacrm.origin=''admin'' maintenance '
  'context) changes that field. Once present, automation can no longer '
  'change that field''s value; a human always can.';


-- ---------------------------------------------------------------------
-- 3. Shared actor helpers
-- ---------------------------------------------------------------------
-- Centralized so the three guard functions below (and every later slice
-- that needs the same "is this a human?" question) read it identically —
-- three copies of this check is exactly how it drifts.

CREATE OR REPLACE FUNCTION wacrm_is_human_actor(
  p_account_id uuid,
  p_min_role account_role_enum DEFAULT 'agent'
) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT is_account_member(p_account_id, p_min_role)
      OR coalesce(current_setting('wacrm.origin', true), '') = 'admin';
$$;

CREATE OR REPLACE FUNCTION wacrm_current_actor()
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    nullif(current_setting('wacrm.actor', true), ''),
    auth.uid()::text
  );
$$;


-- ---------------------------------------------------------------------
-- 4. Lock enforcement — remittance_operations
-- ---------------------------------------------------------------------
-- BEFORE INSERT OR UPDATE (unqualified: a locked field can be any of the
-- six below, not just `status`, so this cannot be scoped the way guard
-- 12a is). On INSERT there is no OLD row to protect, so it is a no-op.

CREATE OR REPLACE FUNCTION remittance_operations_lock_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_human boolean;
  v_actor    text;
  v_locked   jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    RETURN NEW;
  END IF;

  v_is_human := wacrm_is_human_actor(NEW.account_id);
  v_actor    := wacrm_current_actor();
  v_locked   := coalesce(OLD.admin_locked_fields, '{}'::jsonb);

  -- The lock map itself is immutable for automation: only a human write
  -- (or an asserted wacrm.origin='admin' context) may add/remove/edit a
  -- lock entry. This also stops automation from "unlocking" a field by
  -- writing an empty map alongside its own value change.
  IF NOT v_is_human AND NEW.admin_locked_fields IS DISTINCT FROM OLD.admin_locked_fields THEN
    NEW.admin_locked_fields := OLD.admin_locked_fields;
  END IF;

  -- contact_id
  IF NEW.contact_id IS DISTINCT FROM OLD.contact_id THEN
    IF v_locked ? 'contact_id' AND NOT v_is_human THEN
      NEW.contact_id := OLD.contact_id;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (NEW.account_id, 'remittance_operations', OLD.id, 'contact_id', 'automation_write_suppressed', v_actor,
              jsonb_build_object('contact_id', OLD.contact_id), jsonb_build_object('contact_id', NEW.contact_id));
      RAISE WARNING '[wacrm] automation write to remittance_operations %.contact_id suppressed (locked)', OLD.id;
    ELSIF v_is_human THEN
      NEW.admin_locked_fields := jsonb_set(coalesce(NEW.admin_locked_fields, '{}'::jsonb),
        ARRAY['contact_id'], jsonb_build_object('by', v_actor, 'at', now()));
    END IF;
  END IF;

  -- destination_currency
  IF NEW.destination_currency IS DISTINCT FROM OLD.destination_currency THEN
    IF v_locked ? 'destination_currency' AND NOT v_is_human THEN
      NEW.destination_currency := OLD.destination_currency;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (NEW.account_id, 'remittance_operations', OLD.id, 'destination_currency', 'automation_write_suppressed', v_actor,
              jsonb_build_object('destination_currency', OLD.destination_currency), jsonb_build_object('destination_currency', NEW.destination_currency));
      RAISE WARNING '[wacrm] automation write to remittance_operations %.destination_currency suppressed (locked)', OLD.id;
    ELSIF v_is_human THEN
      NEW.admin_locked_fields := jsonb_set(coalesce(NEW.admin_locked_fields, '{}'::jsonb),
        ARRAY['destination_currency'], jsonb_build_object('by', v_actor, 'at', now()));
    END IF;
  END IF;

  -- delivery_method
  IF NEW.delivery_method IS DISTINCT FROM OLD.delivery_method THEN
    IF v_locked ? 'delivery_method' AND NOT v_is_human THEN
      NEW.delivery_method := OLD.delivery_method;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (NEW.account_id, 'remittance_operations', OLD.id, 'delivery_method', 'automation_write_suppressed', v_actor,
              jsonb_build_object('delivery_method', OLD.delivery_method), jsonb_build_object('delivery_method', NEW.delivery_method));
      RAISE WARNING '[wacrm] automation write to remittance_operations %.delivery_method suppressed (locked)', OLD.id;
    ELSIF v_is_human THEN
      NEW.admin_locked_fields := jsonb_set(coalesce(NEW.admin_locked_fields, '{}'::jsonb),
        ARRAY['delivery_method'], jsonb_build_object('by', v_actor, 'at', now()));
    END IF;
  END IF;

  -- deposit_method
  IF NEW.deposit_method IS DISTINCT FROM OLD.deposit_method THEN
    IF v_locked ? 'deposit_method' AND NOT v_is_human THEN
      NEW.deposit_method := OLD.deposit_method;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (NEW.account_id, 'remittance_operations', OLD.id, 'deposit_method', 'automation_write_suppressed', v_actor,
              jsonb_build_object('deposit_method', OLD.deposit_method), jsonb_build_object('deposit_method', NEW.deposit_method));
      RAISE WARNING '[wacrm] automation write to remittance_operations %.deposit_method suppressed (locked)', OLD.id;
    ELSIF v_is_human THEN
      NEW.admin_locked_fields := jsonb_set(coalesce(NEW.admin_locked_fields, '{}'::jsonb),
        ARRAY['deposit_method'], jsonb_build_object('by', v_actor, 'at', now()));
    END IF;
  END IF;

  -- quoted_source_amount (this is the field the deal->operation sync
  -- trigger writes on every deal value change — the primary case
  -- "lock-aware deal->operation sync" exercises)
  IF NEW.quoted_source_amount IS DISTINCT FROM OLD.quoted_source_amount THEN
    IF v_locked ? 'quoted_source_amount' AND NOT v_is_human THEN
      NEW.quoted_source_amount := OLD.quoted_source_amount;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (NEW.account_id, 'remittance_operations', OLD.id, 'quoted_source_amount', 'automation_write_suppressed', v_actor,
              jsonb_build_object('quoted_source_amount', OLD.quoted_source_amount), jsonb_build_object('quoted_source_amount', NEW.quoted_source_amount));
      RAISE WARNING '[wacrm] automation write to remittance_operations %.quoted_source_amount suppressed (locked)', OLD.id;
    ELSIF v_is_human THEN
      NEW.admin_locked_fields := jsonb_set(coalesce(NEW.admin_locked_fields, '{}'::jsonb),
        ARRAY['quoted_source_amount'], jsonb_build_object('by', v_actor, 'at', now()));
    END IF;
  END IF;

  -- quoted_destination_amount
  IF NEW.quoted_destination_amount IS DISTINCT FROM OLD.quoted_destination_amount THEN
    IF v_locked ? 'quoted_destination_amount' AND NOT v_is_human THEN
      NEW.quoted_destination_amount := OLD.quoted_destination_amount;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (NEW.account_id, 'remittance_operations', OLD.id, 'quoted_destination_amount', 'automation_write_suppressed', v_actor,
              jsonb_build_object('quoted_destination_amount', OLD.quoted_destination_amount), jsonb_build_object('quoted_destination_amount', NEW.quoted_destination_amount));
      RAISE WARNING '[wacrm] automation write to remittance_operations %.quoted_destination_amount suppressed (locked)', OLD.id;
    ELSIF v_is_human THEN
      NEW.admin_locked_fields := jsonb_set(coalesce(NEW.admin_locked_fields, '{}'::jsonb),
        ARRAY['quoted_destination_amount'], jsonb_build_object('by', v_actor, 'at', now()));
    END IF;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_admin_field_locks_operations ON remittance_operations;
CREATE TRIGGER trg_admin_field_locks_operations
  BEFORE INSERT OR UPDATE ON remittance_operations
  FOR EACH ROW EXECUTE FUNCTION remittance_operations_lock_guard();


-- ---------------------------------------------------------------------
-- 5. Guard 12a — remittance_operations completed in/out
-- ---------------------------------------------------------------------
-- BEFORE INSERT OR UPDATE OF status, ahead of trg_remittance_operations_touch.

CREATE OR REPLACE FUNCTION remittance_operations_completion_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor text;
BEGIN
  IF wacrm_is_human_actor(NEW.account_id) THEN
    RETURN NEW;
  END IF;
  v_actor := wacrm_current_actor();

  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'completed' THEN
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (NEW.account_id, 'remittance_operations', NEW.id, 'status', 'automation_completion_suppressed', v_actor,
              NULL, jsonb_build_object('attempted_status', 'completed', 'coerced_to', 'incident'));
      NEW.status := 'incident';
      RAISE WARNING '[wacrm] automation insert of remittance_operations % as completed coerced to incident', NEW.id;
    END IF;
    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'
  IF OLD.status IS DISTINCT FROM 'completed' AND NEW.status = 'completed' THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (NEW.account_id, 'remittance_operations', OLD.id, 'status', 'automation_completion_suppressed', v_actor,
            jsonb_build_object('status', OLD.status), jsonb_build_object('attempted_status', NEW.status));
    NEW.status := OLD.status;
    RAISE WARNING '[wacrm] automation completion of remittance_operations % suppressed', OLD.id;
  ELSIF OLD.status = 'completed' AND NEW.status IS DISTINCT FROM 'completed' THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (NEW.account_id, 'remittance_operations', OLD.id, 'status', 'automation_revert_suppressed', v_actor,
            jsonb_build_object('status', OLD.status), jsonb_build_object('attempted_status', NEW.status));
    NEW.status := OLD.status;
    RAISE WARNING '[wacrm] automation revert of completed remittance_operations % suppressed', OLD.id;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_admin_guard_operations_status ON remittance_operations;
CREATE TRIGGER trg_admin_guard_operations_status
  BEFORE INSERT OR UPDATE OF status ON remittance_operations
  FOR EACH ROW EXECUTE FUNCTION remittance_operations_completion_guard();


-- ---------------------------------------------------------------------
-- 6. Guard 12b — deals.stage_id Entregada in/out (remesas pipeline only)
-- ---------------------------------------------------------------------
-- BEFORE INSERT OR UPDATE OF stage_id, ahead of trg_cerrar_deal_entregado.
-- Scoped to the remesas pipeline like every other trigger on this table
-- (041/043/052/060) — other pipelines are not remesa operations.

CREATE OR REPLACE FUNCTION deals_admin_completion_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entregada  CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';
  v_incidencia CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_actor      text;
BEGIN
  IF NEW.pipeline_id <> '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid THEN
    RETURN NEW;
  END IF;

  IF wacrm_is_human_actor(NEW.account_id) THEN
    RETURN NEW;
  END IF;
  v_actor := wacrm_current_actor();

  IF TG_OP = 'INSERT' THEN
    IF NEW.stage_id = v_entregada THEN
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (NEW.account_id, 'deals', NEW.id, 'stage_id', 'automation_completion_suppressed', v_actor,
              NULL, jsonb_build_object('attempted_stage_id', v_entregada, 'coerced_to', v_incidencia));
      NEW.stage_id := v_incidencia;
      RAISE WARNING '[wacrm] automation insert of deal % into Entregada coerced to Incidencia', NEW.id;
    END IF;
    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'
  IF OLD.stage_id IS DISTINCT FROM v_entregada AND NEW.stage_id = v_entregada THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (NEW.account_id, 'deals', OLD.id, 'stage_id', 'automation_completion_suppressed', v_actor,
            jsonb_build_object('stage_id', OLD.stage_id), jsonb_build_object('attempted_stage_id', NEW.stage_id));
    NEW.stage_id := OLD.stage_id;
    RAISE WARNING '[wacrm] automation move of deal % into Entregada suppressed', OLD.id;
  ELSIF OLD.stage_id = v_entregada AND NEW.stage_id IS DISTINCT FROM v_entregada THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (NEW.account_id, 'deals', OLD.id, 'stage_id', 'automation_revert_suppressed', v_actor,
            jsonb_build_object('stage_id', OLD.stage_id), jsonb_build_object('attempted_stage_id', NEW.stage_id));
    NEW.stage_id := OLD.stage_id;
    RAISE WARNING '[wacrm] automation move of deal % out of Entregada suppressed', OLD.id;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_admin_guard_deals_stage ON deals;
CREATE TRIGGER trg_admin_guard_deals_stage
  BEFORE INSERT OR UPDATE OF stage_id ON deals
  FOR EACH ROW EXECUTE FUNCTION deals_admin_completion_guard();


-- =====================================================================
-- VALIDATED ON STAGING (crm.onlinefreedom.site's isolated DB), inside a
-- transaction that always ends in ROLLBACK — see
-- supabase/staging/assertions/guard12-matrix.sql and
-- supabase/staging/assertions/field-lock-persistence.sql for the exact
-- matrix and expectations.
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-096-admin-locks-audit-sync.sql
-- =====================================================================
