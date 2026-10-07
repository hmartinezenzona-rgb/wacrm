-- ROLLBACK of 228_manual_entries.sql: drops crm_sincronizar_entradas_manuales, restores crm_cierre_financiero and
-- remittance_calculator_entries_lock_completed to their exact pre-228 definitions, drops the line_position / raw_line columns.
-- It refuses (and changes nothing) when a manual entry exists: the manual lines (and the Finanzas numbers they feed) would be
-- lost, and the pre-228 guard would let a raw DELETE touch no manual row only because none exist. Export or keep them first.
-- Pre-228 md5 (pg_get_functiondef, staging 2026-10-07; restoring must give the same): crm_cierre_financiero
-- b8ea2475a1b89d60c8414d0c381b176c; remittance_calculator_entries_lock_completed c7c9bd08970ad9dba404ce1b650e045b.
DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE source = 'manual') THEN
    RAISE EXCEPTION 'rollback 228 refused: manual calculator entries exist';
  END IF;
END $guard$;

DROP FUNCTION IF EXISTS public.crm_sincronizar_entradas_manuales(uuid, jsonb);

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

ALTER TABLE remittance_calculator_entries DROP COLUMN IF EXISTS line_position, DROP COLUMN IF EXISTS raw_line;
