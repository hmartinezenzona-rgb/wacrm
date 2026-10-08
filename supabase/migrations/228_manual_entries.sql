-- =====================================================================
-- 228 -- Manual operations as ledger entries: one table for every operation, counted by Finanzas (staging first)
--
-- odd/tasks/manual-entries-in-finanzas.md (T2b, "Design v2"). Owner request (2026-10-07): "todo debe salir en Finanzas,
-- manual y automaticas", and the Calculator keeps ONE table of operations ("Operaciones") that lists the bot's and the
-- manual ones as rows, each with its date, pencil and trash. The text box of the page only ADDS operations.
--   * remittance_calculator_entries.raw_line (nullable; manual rows only): the line as typed, for the record.
--   * crm_registrar_entradas_manuales(p_account_id, p_lineas jsonb): agent+ (the role that saves the Calculator document),
--     SECURITY DEFINER. ADDS the lines as ledger rows: source 'manual', status completed, operation_id NULL, dated on the
--     line's Guyana day (completed_at = midday that day), actor = the caller. Every line is validated first (date within the
--     last 60 days and at most tomorrow, customer, a service of the ledger vocabulary the manual calculator produces,
--     amount above zero, currency, facturado and invertido >= 0, retorno finite) and ALL lines are inserted or NONE (22023).
--     It is an add, not a sync: calling it twice with the same lines adds them twice (the page removes the registered lines
--     from its text box). Returns the created rows (jsonb array, in the order sent). Each row is audited
--     ('human_calculator_manual_added'). Shares the weekly cut's advisory lock, so an add and a cut never interleave.
--   * crm_corregir_entrada_calculadora (149) and crm_eliminar_entrada_calculadora (226) now accept a manual entry too (same
--     fields, same audit, admin+ as before). A manual row has no operation, so void_shape_chk and source_shape_chk now let a
--     manual row be void without one. A voided manual row is durable (deleted_at / deleted_by) and stops counting everywhere.
--   * remittance_calculator_entries_lock_completed: a manual row changes only through those two RPCs (each opens its own
--     narrow GUC: wacrm.calculator_correction, wacrm.calculator_manual_delete); a raw UPDATE, a raw DELETE, and any change
--     to a void manual row are refused (42501); the identity fields (account, source, date, customer, day label, raw line,
--     completed_at) never change.
--   * calculator_current_entries (227) lists the manual entries of the open week (not archived by a cut) next to the bot's.
--   * crm_cerrar_semana_calculadora (227) loses its three client-sent manual totals: the cut archives every entry shown (bot
--     and manual, each with its 'source'), chat_totals = the bot's, manual_totals = the manual entries', both computed here.
--     The archived raw text stays whatever the box held (lines not registered). The week's manual entries stay in the ledger
--     (history keeps counting them), exactly like the bot's. Weeks archived before this change keep their stored shape
--     (their manual_totals came from the text) and still open.
--   * crm_cierre_financiero: counts manual completed entries in totals, per-service and per-day (operaciones = distinct
--     operations + manual entries) and marks every detail / excluded row with 'source' ('completed_operation' | 'manual').
--   * remittance_admin_audit_action_chk gains 'human_calculator_manual_added'.
-- Pre-228 md5 on staging (2026-10-07, pg_get_functiondef; the ROLLBACK restores exactly these): crm_cierre_financiero
-- b8ea2475a1b89d60c8414d0c381b176c; remittance_calculator_entries_lock_completed c7c9bd08970ad9dba404ce1b650e045b;
-- crm_cerrar_semana_calculadora 3a046742358202ef4f259be9aba142d8; crm_corregir_entrada_calculadora
-- dfbd1eb1eec481d9f852b01c143e14f7; crm_eliminar_entrada_calculadora 81ef8a23d752c077a6ee9a0c988b7c8a; calculator_current_entries
-- (md5 of pg_get_viewdef) f7cc9fe7ef434d9009e27502941f32d6; audit action CHECK (md5 of pg_get_constraintdef)
-- 5b3ffc19c3658c9e0c55a724e27be369; void_shape_chk "(status <> 'void') OR (voided_at IS NOT NULL AND operation_id IS NOT NULL)"; source_shape_chk
-- "(manual AND operation_id IS NULL AND status = 'completed') OR (completed_operation AND operation_id IS NOT NULL)".
-- Guarded by supabase/staging/assertions/manual-entries.sql. ROLLBACK: ROLLBACK-228-manual-entries.sql
-- =====================================================================

ALTER TABLE remittance_calculator_entries ADD COLUMN IF NOT EXISTS raw_line text;
COMMENT ON COLUMN remittance_calculator_entries.raw_line IS
  '(228) manual entries only: the line as typed in the Calculator text box, for the record.';

-- A manual row has no operation, so it may be void without one (a bot row still needs its operation).
ALTER TABLE remittance_calculator_entries DROP CONSTRAINT remittance_calculator_entries_void_shape_chk;
ALTER TABLE remittance_calculator_entries ADD CONSTRAINT remittance_calculator_entries_void_shape_chk
  CHECK (status <> 'void' OR (voided_at IS NOT NULL AND (operation_id IS NOT NULL OR source = 'manual')));

-- ... and a manual row may be void (completed -> void, by the deletion RPC only; the guard below).
ALTER TABLE remittance_calculator_entries DROP CONSTRAINT remittance_calculator_entries_source_shape_chk;
ALTER TABLE remittance_calculator_entries ADD CONSTRAINT remittance_calculator_entries_source_shape_chk
  CHECK ((source = 'manual' AND operation_id IS NULL AND status IN ('completed', 'void'))
         OR (source = 'completed_operation' AND operation_id IS NOT NULL));

ALTER TABLE remittance_admin_audit DROP CONSTRAINT remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk CHECK (action = ANY (ARRAY[
  'automation_write_suppressed', 'automation_completion_suppressed', 'automation_revert_suppressed', 'human_correction',
  'human_reassignment', 'human_deposit_verification', 'human_forced_verification', 'human_delivery', 'calculator_feed_failed',
  'calculator_pending_resolved', 'human_beneficiary_added', 'automation_reparto_registered', 'human_calculator_correction',
  'automation_cash_delivery_data_registered', 'automation_late_deposit_verification', 'human_manual_close',
  'human_operation_deleted', 'automation_recharge_numbers_registered', 'automation_combo_recipient_registered',
  'human_combo_cost_set', 'automation_visa_registered', 'human_calculator_entry_deleted', 'human_calculator_manual_added']));

-- The Calculator's list: the bot's entries and the manual ones of the open week.
CREATE OR REPLACE VIEW public.calculator_current_entries WITH (security_invoker = true) AS
 SELECT e.*
   FROM remittance_calculator_entries e
  WHERE e.source IN ('completed_operation', 'manual')
    AND e.status <> 'void'
    AND NOT EXISTS (SELECT 1 FROM remittance_calculator_week_entries we WHERE we.entry_id = e.id);

CREATE OR REPLACE FUNCTION public.crm_registrar_entradas_manuales(p_account_id uuid, p_lineas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_services constant text[] := ARRAY['CUP', 'ZELLE', 'MLC', 'TROPICAL', 'CLASICA', 'USDT', 'SALDO_MOVIL', 'RECARGA', 'DIRECTO'];
  v_today   date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_line    jsonb;
  v_n       integer := 0;
  v_date    date;
  v_entry   remittance_calculator_entries;
  v_out     jsonb := '[]'::jsonb;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(p_account_id, 'agent') THEN
    RAISE EXCEPTION 'not authorized to add calculator entries' USING ERRCODE = '42501';
  END IF;

  IF p_lineas IS NULL OR jsonb_typeof(p_lineas) <> 'array' THEN
    RAISE EXCEPTION 'lines must be a JSON array' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_lineas) = 0 THEN
    RAISE EXCEPTION 'at least one line is required' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_lineas) > 500 THEN
    RAISE EXCEPTION 'too many lines (500 at most)' USING ERRCODE = '22023';
  END IF;

  -- Validate EVERYTHING first: a refused payload writes nothing (the transaction would also undo a half insert).
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lineas) LOOP
    v_n := v_n + 1;
    IF jsonb_typeof(v_line) <> 'object' THEN
      RAISE EXCEPTION 'line %: must be an object', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'customer') IS DISTINCT FROM 'string' OR char_length(btrim(v_line ->> 'customer')) NOT BETWEEN 1 AND 240 THEN
      RAISE EXCEPTION 'line %: customer is required (1 to 240 characters)', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'service') IS DISTINCT FROM 'string' OR NOT (v_line ->> 'service') = ANY (c_services) THEN
      RAISE EXCEPTION 'line %: unknown service', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'currency') IS DISTINCT FROM 'string' OR char_length(v_line ->> 'currency') NOT BETWEEN 1 AND 12 THEN
      RAISE EXCEPTION 'line %: currency is required (1 to 12 characters)', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'amount') IS DISTINCT FROM 'number' OR (v_line ->> 'amount')::numeric <= 0 OR (v_line ->> 'amount')::numeric >= 1e15 THEN
      RAISE EXCEPTION 'line %: amount must be a number above zero', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'facturado_gyd') IS DISTINCT FROM 'number' OR (v_line ->> 'facturado_gyd')::numeric < 0 OR (v_line ->> 'facturado_gyd')::numeric >= 1e15
       OR jsonb_typeof(v_line -> 'invertido_gyd') IS DISTINCT FROM 'number' OR (v_line ->> 'invertido_gyd')::numeric < 0 OR (v_line ->> 'invertido_gyd')::numeric >= 1e15
       OR jsonb_typeof(v_line -> 'retorno_gyd') IS DISTINCT FROM 'number' OR abs((v_line ->> 'retorno_gyd')::numeric) >= 1e15 THEN
      RAISE EXCEPTION 'line %: facturado and invertido must be numbers of zero or more, retorno a number', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'date') IS DISTINCT FROM 'string' OR (v_line ->> 'date') !~ '^\d{4}-\d{2}-\d{2}$' THEN
      RAISE EXCEPTION 'line %: date must be YYYY-MM-DD', v_n USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_date := (v_line ->> 'date')::date;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'line %: date is not a valid day', v_n USING ERRCODE = '22023';
    END;
    IF v_date > v_today + 1 OR v_date < v_today - 60 THEN
      RAISE EXCEPTION 'line %: date out of range', v_n USING ERRCODE = '22023';
    END IF;
    IF v_line ? 'day_label' AND jsonb_typeof(v_line -> 'day_label') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'line %: day_label must be text', v_n USING ERRCODE = '22023';
    END IF;
    IF v_line ? 'raw_line' AND jsonb_typeof(v_line -> 'raw_line') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'line %: raw_line must be text', v_n USING ERRCODE = '22023';
    END IF;
  END LOOP;

  PERFORM pg_advisory_xact_lock(hashtextextended('calculator-cut:' || p_account_id::text, 0));

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lineas) LOOP
    v_date := (v_line ->> 'date')::date;

    INSERT INTO remittance_calculator_entries (
      account_id, source, status, operation_id, entry_date, day_label, customer_name, service, amount, amount_currency,
      facturado_gyd, invertido_gyd, retorno_gyd, actor_user_id, completed_at, created_at, raw_line
    ) VALUES (
      p_account_id, 'manual', 'completed', NULL, v_date, nullif(left(v_line ->> 'day_label', 120), ''), btrim(v_line ->> 'customer'),
      v_line ->> 'service', (v_line ->> 'amount')::numeric, v_line ->> 'currency',
      (v_line ->> 'facturado_gyd')::numeric, (v_line ->> 'invertido_gyd')::numeric, (v_line ->> 'retorno_gyd')::numeric,
      auth.uid(),
      -- midday of the line's Guyana day, so the close files it on that day whatever the viewer's zone
      (v_date + time '12:00') AT TIME ZONE 'America/Guyana',
      -- strictly increasing inside the batch, so the rows keep the order they were sent in
      clock_timestamp(), nullif(left(v_line ->> 'raw_line', 1000), '')
    )
    RETURNING * INTO v_entry;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id, 'created', 'human_calculator_manual_added',
            wacrm_current_actor(), NULL, to_jsonb(v_entry));

    v_out := v_out || to_jsonb(v_entry);
  END LOOP;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.crm_registrar_entradas_manuales(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_registrar_entradas_manuales(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION public.crm_registrar_entradas_manuales(uuid, jsonb) IS
  'Agent+ only. ADDS manual Calculator entries (source manual, completed, no operation) dated on each line''s Guyana day; all '
  'lines or none. An add, not a sync: the same lines sent twice are added twice. Returns the created rows.';

CREATE OR REPLACE FUNCTION public.remittance_calculator_entries_lock_completed()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_correcting boolean := coalesce(current_setting('wacrm.calculator_correction', true), '') = 'true';
  -- (228) crm_eliminar_entrada_calculadora is the ONLY caller ever allowed to set this GUC, for its own UPDATE.
  v_deleting   boolean := coalesce(current_setting('wacrm.calculator_manual_delete', true), '') = 'true';
BEGIN
  -- (228) a manual row (an operation typed in the Calculator) changes only through the correction or the deletion RPC.
  IF OLD.source = 'manual' OR (TG_OP = 'UPDATE' AND NEW.source = 'manual') THEN
    IF TG_OP = 'DELETE' OR OLD.source IS DISTINCT FROM NEW.source OR OLD.status <> 'completed'
       OR NOT ((v_correcting AND NEW.status = 'completed') OR (v_deleting AND NEW.status = 'void')) THEN
      RAISE EXCEPTION 'remittance_calculator_entries: a manual row changes only through the correction or the deletion of the Calculator'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.account_id IS DISTINCT FROM OLD.account_id
       OR NEW.entry_date IS DISTINCT FROM OLD.entry_date
       OR NEW.customer_name IS DISTINCT FROM OLD.customer_name
       OR NEW.day_label IS DISTINCT FROM OLD.day_label
       OR NEW.raw_line IS DISTINCT FROM OLD.raw_line
       OR NEW.completed_at IS DISTINCT FROM OLD.completed_at
       OR NEW.amount_currency IS DISTINCT FROM OLD.amount_currency
    THEN
      RAISE EXCEPTION 'remittance_calculator_entries: a manual row keeps its account, date, customer and typed line'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'completed' THEN
      RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.status = 'completed' THEN
    -- (149) crm_corregir_entrada_calculadora is the ONLY caller ever
    -- allowed to set this GUC, and only for the duration of its own
    -- UPDATE. It may revise facturado_gyd/invertido_gyd/retorno_gyd
    -- WITHOUT voiding the row; every other figure this guard already
    -- protected must still survive untouched.
    IF v_correcting AND NEW.status = 'completed' THEN
      IF NEW.amount          IS DISTINCT FROM OLD.amount
         OR NEW.service        IS DISTINCT FROM OLD.service
         OR NEW.operation_id   IS DISTINCT FROM OLD.operation_id
         OR NEW.rate_version_id IS DISTINCT FROM OLD.rate_version_id
      THEN
        RAISE EXCEPTION 'remittance_calculator_entries: a correction may only change facturado_gyd, invertido_gyd and retorno_gyd'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      RETURN NEW;
    END IF;

    -- The only other permitted change is voiding it, and even then every
    -- figure must survive untouched so the audit trail stays readable.
    IF NEW.status <> 'void' THEN
      RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NEW.amount        IS DISTINCT FROM OLD.amount
       OR NEW.service       IS DISTINCT FROM OLD.service
       OR NEW.operation_id  IS DISTINCT FROM OLD.operation_id
       OR NEW.facturado_gyd IS DISTINCT FROM OLD.facturado_gyd
       OR NEW.invertido_gyd IS DISTINCT FROM OLD.invertido_gyd
       OR NEW.retorno_gyd   IS DISTINCT FROM OLD.retorno_gyd
       OR NEW.rate_version_id IS DISTINCT FROM OLD.rate_version_id
    THEN
      RAISE EXCEPTION 'remittance_calculator_entries: voiding must not alter the recorded figures'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_corregir_entrada_calculadora(p_entry_id uuid, p_facturado_gyd numeric, p_invertido_gyd numeric)
 RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry  remittance_calculator_entries;
  v_before jsonb;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to correct calculator entries' USING ERRCODE = '42501';
  END IF;

  -- (228) a chat-fed entry or a manual one (both are rows of the Calculator's table).
  IF v_entry.source NOT IN ('completed_operation', 'manual') THEN
    RAISE EXCEPTION 'only a chat-fed or a manual entry can be corrected here' USING ERRCODE = '22023';
  END IF;

  IF v_entry.status NOT IN ('completed', 'verified_pending') THEN
    RAISE EXCEPTION 'entry is % and cannot be corrected here', v_entry.status USING ERRCODE = '22023';
  END IF;

  IF p_facturado_gyd IS NULL OR p_facturado_gyd < 0 OR p_facturado_gyd >= 1e15 THEN
    RAISE EXCEPTION 'facturado_gyd must be zero or greater' USING ERRCODE = '22023';
  END IF;

  IF p_invertido_gyd IS NULL OR p_invertido_gyd < 0 OR p_invertido_gyd >= 1e15 THEN
    RAISE EXCEPTION 'invertido_gyd must be zero or greater' USING ERRCODE = '22023';
  END IF;

  v_before := to_jsonb(v_entry);

  -- Open the append-only guard's narrow hole for exactly this UPDATE.
  PERFORM set_config('wacrm.calculator_correction', 'true', true);

  UPDATE remittance_calculator_entries
     SET facturado_gyd  = p_facturado_gyd,
         invertido_gyd  = p_invertido_gyd,
         retorno_gyd    = p_facturado_gyd - p_invertido_gyd,
         status         = 'completed',
         missing_inputs = NULL
   WHERE id = p_entry_id
  RETURNING * INTO v_entry;

  PERFORM set_config('wacrm.calculator_correction', '', true);

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id,
          'facturado_gyd,invertido_gyd,retorno_gyd,status', 'human_calculator_correction',
          wacrm_current_actor(), v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_eliminar_entrada_calculadora(p_entry_id uuid)
 RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry  remittance_calculator_entries;
  v_before jsonb;
  v_actor  text;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to delete calculator entries' USING ERRCODE = '42501';
  END IF;

  -- (228) a chat-fed entry or a manual one (both are rows of the Calculator's table).
  IF v_entry.source NOT IN ('completed_operation', 'manual') THEN
    RAISE EXCEPTION 'only a chat-fed or a manual entry can be deleted here' USING ERRCODE = '22023';
  END IF;

  IF v_entry.status NOT IN ('completed', 'verified_pending') THEN
    RAISE EXCEPTION 'entry is % and cannot be deleted', v_entry.status USING ERRCODE = '22023';
  END IF;

  v_before := to_jsonb(v_entry);
  v_actor  := wacrm_current_actor();

  -- Open the append-only guard's narrow hole for exactly this UPDATE (a manual row has no other way to be voided).
  PERFORM set_config('wacrm.calculator_manual_delete', 'true', true);

  -- completed -> void keeps every figure (the append-only guard checks it); the deletion marker is not a figure.
  UPDATE remittance_calculator_entries
     SET status      = 'void',
         voided_at   = clock_timestamp(),
         void_reason = 'deleted by ' || coalesce(v_actor, 'unknown'),
         deleted_at  = clock_timestamp(),
         deleted_by  = auth.uid()
   WHERE id = p_entry_id
  RETURNING * INTO v_entry;

  PERFORM set_config('wacrm.calculator_manual_delete', '', true);

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id, 'status,deleted_at',
          'human_calculator_entry_deleted', v_actor, v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$;

-- The weekly cut no longer takes manual totals from the client: the manual entries are rows now, so both totals are
-- computed here. The entries snapshot carries each entry's source.
DROP FUNCTION IF EXISTS public.crm_cerrar_semana_calculadora(uuid, text, text, numeric, numeric, numeric);

CREATE OR REPLACE FUNCTION public.crm_cerrar_semana_calculadora(p_account_id uuid, p_raw_text text, p_period_label text)
 RETURNS remittance_calculator_weeks
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_week    remittance_calculator_weeks;
  v_ids     uuid[];
  v_entries jsonb;
  v_chat    jsonb;
  v_manual  jsonb;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(p_account_id, 'agent') THEN
    RAISE EXCEPTION 'not authorized to clear the calculator' USING ERRCODE = '42501';
  END IF;

  IF p_raw_text IS NULL OR p_period_label IS NULL THEN
    RAISE EXCEPTION 'raw_text and period_label are required' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('calculator-cut:' || p_account_id::text, 0));

  -- The entries shown: completed, not void, not archived by an earlier cut, the bot's and the manual ones. A pending
  -- line is never archived.
  SELECT coalesce(array_agg(c.id ORDER BY c.entry_date, c.created_at, c.id), ARRAY[]::uuid[]),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'operation_id', c.operation_id, 'source', c.source, 'service', c.service, 'customer_name', c.customer_name,
           'amount', c.amount, 'amount_currency', c.amount_currency, 'entry_date', c.entry_date,
           'facturado_gyd', c.facturado_gyd, 'invertido_gyd', c.invertido_gyd, 'retorno_gyd', c.retorno_gyd)
           ORDER BY c.entry_date, c.created_at, c.id), '[]'::jsonb),
         jsonb_build_object('count', count(*) FILTER (WHERE c.source = 'completed_operation'),
                            'facturado_gyd', coalesce(sum(c.facturado_gyd) FILTER (WHERE c.source = 'completed_operation'), 0),
                            'invertido_gyd', coalesce(sum(c.invertido_gyd) FILTER (WHERE c.source = 'completed_operation'), 0),
                            'retorno_gyd',   coalesce(sum(c.retorno_gyd)   FILTER (WHERE c.source = 'completed_operation'), 0)),
         jsonb_build_object('count', count(*) FILTER (WHERE c.source = 'manual'),
                            'facturado_gyd', coalesce(sum(c.facturado_gyd) FILTER (WHERE c.source = 'manual'), 0),
                            'invertido_gyd', coalesce(sum(c.invertido_gyd) FILTER (WHERE c.source = 'manual'), 0),
                            'retorno_gyd',   coalesce(sum(c.retorno_gyd)   FILTER (WHERE c.source = 'manual'), 0))
    INTO v_ids, v_entries, v_chat, v_manual
    FROM calculator_current_entries c
   WHERE c.account_id = p_account_id AND c.status = 'completed';

  INSERT INTO remittance_calculator_weeks (account_id, cut_by, raw_text, period_label, manual_totals, chat_totals, entries)
  VALUES (p_account_id, auth.uid(), p_raw_text, p_period_label, v_manual, v_chat, v_entries)
  RETURNING * INTO v_week;

  INSERT INTO remittance_calculator_week_entries (entry_id, week_id, account_id)
  SELECT id, v_week.id, p_account_id FROM unnest(v_ids) AS id;

  INSERT INTO remittance_calculator_documents (account_id, raw_text, period_label, updated_by, updated_at)
  VALUES (p_account_id, '', '', auth.uid(), clock_timestamp())
  ON CONFLICT (account_id) DO UPDATE
    SET raw_text     = '',
        period_label = '',
        updated_by   = EXCLUDED.updated_by,
        updated_at   = EXCLUDED.updated_at;

  RETURN v_week;
END;
$function$;

REVOKE ALL ON FUNCTION public.crm_cerrar_semana_calculadora(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cerrar_semana_calculadora(uuid, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.crm_cierre_financiero(p_desde date, p_hasta date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'crm_cierre_financiero: p_desde and p_hasta are required'
      USING ERRCODE = '22023';
  END IF;

  IF p_desde > p_hasta THEN
    RAISE EXCEPTION 'crm_cierre_financiero: p_desde (%) must not be after p_hasta (%)',
      p_desde, p_hasta
      USING ERRCODE = '22023';
  END IF;

  -- Inclusive day count = (p_hasta - p_desde) + 1; capped at 366 (a leap
  -- year), so the cap on the raw difference is 365.
  IF (p_hasta - p_desde) > 365 THEN
    RAISE EXCEPTION 'crm_cierre_financiero: range must not exceed 366 days (requested % days)',
      (p_hasta - p_desde) + 1
      USING ERRCODE = '22023';
  END IF;

  WITH scoped AS (
    -- Every ledger row (a bot operation's or a manual Calculator line, 228) this caller is allowed to see,
    -- with its Guyana business day precomputed once.
    SELECT
      e.*,
      coalesce((e.completed_at AT TIME ZONE 'America/Guyana')::date,
               e.entry_date) AS dia
    FROM remittance_calculator_entries e
    WHERE e.source IN ('completed_operation', 'manual')
      AND is_account_member(e.account_id)
  ),
  in_range AS (
    SELECT * FROM scoped WHERE dia BETWEEN p_desde AND p_hasta
  ),
  completed AS (
    SELECT * FROM in_range WHERE status = 'completed'
  ),
  totales AS (
    SELECT
      count(DISTINCT operation_id) + count(*) FILTER (WHERE source = 'manual') AS operaciones,
      coalesce(sum(facturado_gyd), 0) AS facturado_gyd,
      coalesce(sum(invertido_gyd), 0) AS invertido_gyd,
      coalesce(sum(retorno_gyd), 0)   AS retorno_gyd
    FROM completed
  ),
  por_servicio AS (
    SELECT
      service,
      count(*)                        AS operaciones,
      coalesce(sum(facturado_gyd), 0) AS facturado_gyd,
      coalesce(sum(invertido_gyd), 0) AS invertido_gyd,
      coalesce(sum(retorno_gyd), 0)   AS retorno_gyd
    FROM completed
    GROUP BY service
  ),
  dias AS (
    -- Every calendar day in the range, so por_dia never has a gap.
    SELECT gs::date AS dia FROM generate_series(p_desde, p_hasta, interval '1 day') gs
  ),
  por_dia AS (
    SELECT
      d.dia,
      count(DISTINCT c.operation_id) + count(c.id) FILTER (WHERE c.source = 'manual') AS operaciones,
      coalesce(sum(c.facturado_gyd), 0)  AS facturado_gyd,
      coalesce(sum(c.invertido_gyd), 0)  AS invertido_gyd,
      coalesce(sum(c.retorno_gyd), 0)    AS retorno_gyd
    FROM dias d
    LEFT JOIN completed c ON c.dia = d.dia
    GROUP BY d.dia
  ),
  detalle AS (
    SELECT
      c.id, c.operation_id, c.source, c.dia, c.completed_at, c.customer_name, c.service,
      c.amount, c.amount_currency, c.cup_rate, c.cup_global_rate,
      c.usdt_buy_gyd, c.usdt_sell_gyd, c.rate_version_id,
      c.facturado_gyd, c.invertido_gyd, c.retorno_gyd,
      c.delivery_mode, c.actor_user_id,
      coalesce(nullif(p.full_name, ''), p.email) AS actor_name
    FROM completed c
    LEFT JOIN profiles p ON p.user_id = c.actor_user_id
  ),
  excluidas AS (
    -- Voided and pending-rate rows never touch a total but must stay
    -- visible: a voided figure for the audit trail, a pending one to show
    -- what is still waiting on a rate.
    SELECT
      c.id, c.operation_id, c.source, c.dia, c.completed_at, c.customer_name, c.service,
      c.amount, c.amount_currency, c.cup_rate, c.cup_global_rate,
      c.usdt_buy_gyd, c.usdt_sell_gyd, c.rate_version_id,
      c.facturado_gyd, c.invertido_gyd, c.retorno_gyd,
      c.delivery_mode, c.actor_user_id,
      coalesce(nullif(p.full_name, ''), p.email) AS actor_name,
      c.status, c.void_reason, c.voided_at, c.missing_inputs
    FROM in_range c
    LEFT JOIN profiles p ON p.user_id = c.actor_user_id
    WHERE c.status IN ('void', 'verified_pending')
  )
  SELECT jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'zona',  'America/Guyana',

    'totales', (
      SELECT jsonb_build_object(
        'operaciones',    t.operaciones,
        'facturado_gyd',  t.facturado_gyd,
        'invertido_gyd',  t.invertido_gyd,
        'retorno_gyd',    t.retorno_gyd
      )
      FROM totales t
    ),

    'por_servicio', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'service',        s.service,
          'operaciones',    s.operaciones,
          'facturado_gyd',  s.facturado_gyd,
          'invertido_gyd',  s.invertido_gyd,
          'retorno_gyd',    s.retorno_gyd
        )
        ORDER BY s.facturado_gyd DESC
      )
      FROM por_servicio s
    ), '[]'::jsonb),

    'por_dia', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'dia',            d.dia,
          'operaciones',    d.operaciones,
          'facturado_gyd',  d.facturado_gyd,
          'invertido_gyd',  d.invertido_gyd,
          'retorno_gyd',    d.retorno_gyd
        )
        ORDER BY d.dia ASC
      )
      FROM por_dia d
    ), '[]'::jsonb),

    'detalle', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',              e.id,
          'operation_id',    e.operation_id,
          'source',          e.source,
          'dia',             e.dia,
          'completed_at',    e.completed_at,
          'customer_name',   e.customer_name,
          'service',         e.service,
          'amount',          e.amount,
          'amount_currency', e.amount_currency,
          'cup_rate',        e.cup_rate,
          'cup_global_rate', e.cup_global_rate,
          'usdt_buy_gyd',    e.usdt_buy_gyd,
          'usdt_sell_gyd',   e.usdt_sell_gyd,
          'rate_version_id', e.rate_version_id,
          'facturado_gyd',   e.facturado_gyd,
          'invertido_gyd',   e.invertido_gyd,
          'retorno_gyd',     e.retorno_gyd,
          'delivery_mode',   e.delivery_mode,
          'actor_user_id',   e.actor_user_id,
          'actor_name',      e.actor_name
        )
        ORDER BY e.completed_at ASC
      )
      FROM detalle e
    ), '[]'::jsonb),

    'excluidas', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',              e.id,
          'operation_id',    e.operation_id,
          'source',          e.source,
          'dia',             e.dia,
          'completed_at',    e.completed_at,
          'customer_name',   e.customer_name,
          'service',         e.service,
          'amount',          e.amount,
          'amount_currency', e.amount_currency,
          'cup_rate',        e.cup_rate,
          'cup_global_rate', e.cup_global_rate,
          'usdt_buy_gyd',    e.usdt_buy_gyd,
          'usdt_sell_gyd',   e.usdt_sell_gyd,
          'rate_version_id', e.rate_version_id,
          'facturado_gyd',   e.facturado_gyd,
          'invertido_gyd',   e.invertido_gyd,
          'retorno_gyd',     e.retorno_gyd,
          'delivery_mode',   e.delivery_mode,
          'actor_user_id',   e.actor_user_id,
          'actor_name',      e.actor_name,
          'status',          e.status,
          'void_reason',     e.void_reason,
          'voided_at',       e.voided_at,
          'missing_inputs',  e.missing_inputs
        )
        ORDER BY e.completed_at ASC
      )
      FROM excluidas e
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;
