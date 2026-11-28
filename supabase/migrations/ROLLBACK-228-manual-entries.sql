-- ROLLBACK of 228_manual_entries.sql (manual operations as ledger entries): restores the pre-228 definitions exactly and drops
-- crm_registrar_entradas_manuales and the raw_line column.
-- It refuses (and changes nothing) when a manual entry exists, void or not: the manual operations (and the Finanzas numbers they
-- feed) would be lost, and the pre-228 guard and void_shape_chk would no longer describe them. Export or keep them first.
-- Pre-228 md5 (pg_get_functiondef, staging 2026-10-07; restoring must give the same): crm_cierre_financiero
-- b8ea2475a1b89d60c8414d0c381b176c; remittance_calculator_entries_lock_completed c7c9bd08970ad9dba404ce1b650e045b;
-- crm_cerrar_semana_calculadora 3a046742358202ef4f259be9aba142d8; crm_corregir_entrada_calculadora
-- dfbd1eb1eec481d9f852b01c143e14f7; crm_eliminar_entrada_calculadora 81ef8a23d752c077a6ee9a0c988b7c8a; calculator_current_entries
-- (md5 of pg_get_viewdef) f7cc9fe7ef434d9009e27502941f32d6; audit action CHECK (md5 of pg_get_constraintdef)
-- 5b3ffc19c3658c9e0c55a724e27be369.
-- Weeks archived after 228 keep their stored jsonb (their entries carry a 'source' key and a null operation_id for manual ones);
-- the pre-228 cut and the pre-228 page ignore both.
DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE source = 'manual') THEN
    RAISE EXCEPTION 'rollback 228 refused: manual calculator entries exist';
  END IF;
  IF EXISTS (SELECT 1 FROM remittance_admin_audit WHERE action = 'human_calculator_manual_added') THEN
    RAISE EXCEPTION 'rollback 228 refused: audit rows of manual additions exist';
  END IF;
END $guard$;

DROP FUNCTION IF EXISTS public.crm_registrar_entradas_manuales(uuid, jsonb);
DROP FUNCTION IF EXISTS public.crm_cerrar_semana_calculadora(uuid, text, text);

-- The pre-228 corrector, deleter and weekly cut (6 arguments), as they were on staging.
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

  IF v_entry.source <> 'completed_operation' THEN
    RAISE EXCEPTION 'only a chat-fed entry can be corrected here' USING ERRCODE = '22023';
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
$function$
;
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

  IF v_entry.source <> 'completed_operation' THEN
    RAISE EXCEPTION 'only a chat-fed entry can be deleted here' USING ERRCODE = '22023';
  END IF;

  IF v_entry.status NOT IN ('completed', 'verified_pending') THEN
    RAISE EXCEPTION 'entry is % and cannot be deleted', v_entry.status USING ERRCODE = '22023';
  END IF;

  v_before := to_jsonb(v_entry);
  v_actor  := wacrm_current_actor();

  -- completed -> void keeps every figure (the append-only guard checks it); the deletion marker is not a figure.
  UPDATE remittance_calculator_entries
     SET status      = 'void',
         voided_at   = clock_timestamp(),
         void_reason = 'deleted by ' || coalesce(v_actor, 'unknown'),
         deleted_at  = clock_timestamp(),
         deleted_by  = auth.uid()
   WHERE id = p_entry_id
  RETURNING * INTO v_entry;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id, 'status,deleted_at',
          'human_calculator_entry_deleted', v_actor, v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.crm_cerrar_semana_calculadora(p_account_id uuid, p_raw_text text, p_period_label text, p_manual_facturado numeric, p_manual_invertido numeric, p_manual_retorno numeric)
 RETURNS remittance_calculator_weeks
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_week    remittance_calculator_weeks;
  v_ids     uuid[];
  v_entries jsonb;
  v_totals  jsonb;
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

  IF p_manual_facturado IS NULL OR p_manual_invertido IS NULL OR p_manual_retorno IS NULL
     OR abs(p_manual_facturado) >= 1e15 OR abs(p_manual_invertido) >= 1e15 OR abs(p_manual_retorno) >= 1e15 THEN
    RAISE EXCEPTION 'the manual totals are required and must be below 1e15' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('calculator-cut:' || p_account_id::text, 0));

  -- The entries shown: completed, not void, not archived by an earlier cut. A pending line is never archived.
  SELECT coalesce(array_agg(c.id ORDER BY c.entry_date, c.created_at, c.id), ARRAY[]::uuid[]),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'operation_id', c.operation_id, 'service', c.service, 'customer_name', c.customer_name,
           'amount', c.amount, 'amount_currency', c.amount_currency, 'entry_date', c.entry_date,
           'facturado_gyd', c.facturado_gyd, 'invertido_gyd', c.invertido_gyd, 'retorno_gyd', c.retorno_gyd)
           ORDER BY c.entry_date, c.created_at, c.id), '[]'::jsonb),
         jsonb_build_object('count', count(*),
                            'facturado_gyd', coalesce(sum(c.facturado_gyd), 0),
                            'invertido_gyd', coalesce(sum(c.invertido_gyd), 0),
                            'retorno_gyd',   coalesce(sum(c.retorno_gyd), 0))
    INTO v_ids, v_entries, v_totals
    FROM calculator_current_entries c
   WHERE c.account_id = p_account_id AND c.status = 'completed';

  INSERT INTO remittance_calculator_weeks (account_id, cut_by, raw_text, period_label, manual_totals, chat_totals, entries)
  VALUES (p_account_id, auth.uid(), p_raw_text, p_period_label,
          jsonb_build_object('facturado_gyd', p_manual_facturado, 'invertido_gyd', p_manual_invertido, 'retorno_gyd', p_manual_retorno),
          v_totals, v_entries)
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
$function$
;

REVOKE ALL ON FUNCTION public.crm_cerrar_semana_calculadora(uuid, text, text, numeric, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cerrar_semana_calculadora(uuid, text, text, numeric, numeric, numeric) TO authenticated, service_role;

DROP VIEW IF EXISTS public.calculator_current_entries;
ALTER TABLE remittance_calculator_entries DROP COLUMN IF EXISTS raw_line;
CREATE VIEW public.calculator_current_entries WITH (security_invoker = true) AS
 SELECT e.*
   FROM remittance_calculator_entries e
  WHERE e.source = 'completed_operation'
    AND e.status <> 'void'
    AND NOT EXISTS (SELECT 1 FROM remittance_calculator_week_entries we WHERE we.entry_id = e.id);
REVOKE ALL ON public.calculator_current_entries FROM PUBLIC, anon;
GRANT SELECT ON public.calculator_current_entries TO authenticated, service_role;

ALTER TABLE remittance_calculator_entries DROP CONSTRAINT remittance_calculator_entries_void_shape_chk;
ALTER TABLE remittance_calculator_entries ADD CONSTRAINT remittance_calculator_entries_void_shape_chk
  CHECK (status <> 'void' OR (voided_at IS NOT NULL AND operation_id IS NOT NULL));

ALTER TABLE remittance_calculator_entries DROP CONSTRAINT remittance_calculator_entries_source_shape_chk;
ALTER TABLE remittance_calculator_entries ADD CONSTRAINT remittance_calculator_entries_source_shape_chk
  CHECK ((source = 'manual' AND operation_id IS NULL AND status = 'completed')
         OR (source = 'completed_operation' AND operation_id IS NOT NULL));

ALTER TABLE remittance_admin_audit DROP CONSTRAINT remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk CHECK (action = ANY (ARRAY[
  'automation_write_suppressed', 'automation_completion_suppressed', 'automation_revert_suppressed', 'human_correction',
  'human_reassignment', 'human_deposit_verification', 'human_forced_verification', 'human_delivery', 'calculator_feed_failed',
  'calculator_pending_resolved', 'human_beneficiary_added', 'automation_reparto_registered', 'human_calculator_correction',
  'automation_cash_delivery_data_registered', 'automation_late_deposit_verification', 'human_manual_close',
  'human_operation_deleted', 'automation_recharge_numbers_registered', 'automation_combo_recipient_registered',
  'human_combo_cost_set', 'automation_visa_registered', 'human_calculator_entry_deleted']));

CREATE OR REPLACE FUNCTION public.remittance_calculator_entries_lock_completed()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_correcting boolean := coalesce(current_setting('wacrm.calculator_correction', true), '') = 'true';
BEGIN
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
    -- Every completed-operation ledger row this caller is allowed to see,
    -- with its Guyana business day precomputed once.
    SELECT
      e.*,
      coalesce((e.completed_at AT TIME ZONE 'America/Guyana')::date,
               e.entry_date) AS dia
    FROM remittance_calculator_entries e
    WHERE e.source = 'completed_operation'
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
      count(DISTINCT operation_id)    AS operaciones,
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
      count(DISTINCT c.operation_id)     AS operaciones,
      coalesce(sum(c.facturado_gyd), 0)  AS facturado_gyd,
      coalesce(sum(c.invertido_gyd), 0)  AS invertido_gyd,
      coalesce(sum(c.retorno_gyd), 0)    AS retorno_gyd
    FROM dias d
    LEFT JOIN completed c ON c.dia = d.dia
    GROUP BY d.dia
  ),
  detalle AS (
    SELECT
      c.id, c.operation_id, c.dia, c.completed_at, c.customer_name, c.service,
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
      c.id, c.operation_id, c.dia, c.completed_at, c.customer_name, c.service,
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

