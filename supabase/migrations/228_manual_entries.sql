-- =====================================================================
-- 228 -- Manual Calculator lines as ledger entries, so Finanzas counts them (staging first)
--
-- odd/tasks/manual-entries-in-finanzas.md (T1). Owner request (2026-10-07): "todo debe salir en Finanzas, manual y
-- automaticas". The manual lines typed in the Calculator were client-parsed text only (remittance_calculator_documents.raw_text)
-- and counted nowhere but the Calculator totals. Now the page sends the parsed lines with the autosave and one RPC keeps
-- the ledger in step with the text:
--   * remittance_calculator_entries.line_position / raw_line (nullable; manual rows only): the typed line and its place.
--   * crm_sincronizar_entradas_manuales(p_account_id, p_lineas jsonb): agent+ (the role that saves the document today),
--     SECURITY DEFINER. Replaces the account's manual entries of the CURRENT week with the set sent: rows source 'manual',
--     status completed, operation_id NULL, dated on the line's Guyana day (completed_at = midday that day). Identity of a
--     row = (cycle, position) in source_event_id 'manual:<cycle>:<position>', where cycle = the weekly cuts so far
--     (remittance_calculator_weeks), so a cut moves the account to a new key space and the closed week's rows can never
--     be matched, updated or deleted by a later sync. Idempotent (an unchanged row is not written), a changed line
--     updates in place, a missing line is deleted, an empty set clears the week. All lines validated first (22023), a
--     refused payload writes nothing; the sync shares the cut's advisory lock. The nine services the manual calculator can
--     produce are accepted (CUP, ZELLE, MLC, TROPICAL, CLASICA, USDT, SALDO_MOVIL, RECARGA and DIRECTO, which is the
--     parser's group TRAMITES / COMBOS / SERVICIOS); all are already in the service CHECK, so the CHECK is NOT changed.
--   * remittance_calculator_entries_lock_completed (149): a manual row changes only while the sync holds the GUC
--     wacrm.calculator_manual_sync (set by the RPC alone); every other UPDATE / DELETE of a manual row is refused
--     (42501). The chat delete (226) and the correction (149) keep refusing manual rows (22023): a manual line is edited
--     from the text.
--   * crm_cierre_financiero: counts manual completed entries in totals, per-service and per-day (operaciones = distinct
--     operations + manual entries) and marks every detail / excluded row with 'source' ('completed_operation' | 'manual').
--     calculator_current_entries (227) is NOT changed: the Calculator list keeps showing only the bot's entries.
--   * The weekly cut (227) is NOT changed: it archives the chat entries; manual rows stay in the ledger and keep counting.
-- Pre-migration md5 on staging (2026-10-07, pg_get_functiondef): crm_cierre_financiero b8ea2475a1b89d60c8414d0c381b176c;
-- remittance_calculator_entries_lock_completed c7c9bd08970ad9dba404ce1b650e045b. Unchanged and re-asserted:
-- crm_cerrar_semana_calculadora 3a046742358202ef4f259be9aba142d8, crm_guardar_documento_calculadora
-- e08e8f9b58127b2828bbb4a812f7d579, crm_eliminar_entrada_calculadora 81ef8a23d752c077a6ee9a0c988b7c8a,
-- crm_corregir_entrada_calculadora dfbd1eb1eec481d9f852b01c143e14f7, calculator_current_entries view
-- f7cc9fe7ef434d9009e27502941f32d6, service CHECK 8b225bc368f61f81c1fab44da2254909.
-- Guarded by supabase/staging/assertions/manual-entries.sql. ROLLBACK: ROLLBACK-228-manual-entries.sql
-- =====================================================================

ALTER TABLE remittance_calculator_entries
  ADD COLUMN IF NOT EXISTS line_position integer,
  ADD COLUMN IF NOT EXISTS raw_line text;
COMMENT ON COLUMN remittance_calculator_entries.line_position IS
  '(228) manual entries only: the line number of the typed line in the Calculator text (its identity inside the week).';
COMMENT ON COLUMN remittance_calculator_entries.raw_line IS
  '(228) manual entries only: the line as typed in the Calculator text, for display.';

CREATE OR REPLACE FUNCTION public.crm_sincronizar_entradas_manuales(p_account_id uuid, p_lineas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_services constant text[] := ARRAY['CUP', 'ZELLE', 'MLC', 'TROPICAL', 'CLASICA', 'USDT', 'SALDO_MOVIL', 'RECARGA', 'DIRECTO'];
  v_today   date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_cycle   integer;
  v_prefix  text;
  v_line    jsonb;
  v_pos     integer;
  v_date    date;
  v_cust    text;
  v_svc     text;
  v_amount  numeric;
  v_cur     text;
  v_f       numeric;
  v_i       numeric;
  v_r       numeric;
  v_seen    integer[] := ARRAY[]::integer[];
  v_keys    text[]    := ARRAY[]::text[];
  v_tot     jsonb;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(p_account_id, 'agent') THEN
    RAISE EXCEPTION 'not authorized to edit the calculator document' USING ERRCODE = '42501';
  END IF;

  IF p_lineas IS NULL OR jsonb_typeof(p_lineas) <> 'array' THEN
    RAISE EXCEPTION 'lines must be a JSON array' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_lineas) > 3000 THEN
    RAISE EXCEPTION 'too many lines (3000 at most)' USING ERRCODE = '22023';
  END IF;

  -- One writer per account, and the same lock as the weekly cut: a sync and a cut never interleave.
  PERFORM pg_advisory_xact_lock(hashtextextended('calculator-cut:' || p_account_id::text, 0));

  -- The current week = the cuts so far. A cut moves the account to the next cycle, so the rows of a closed week are
  -- never in the key space of the current one and nothing below can touch them.
  SELECT count(*) INTO v_cycle FROM remittance_calculator_weeks WHERE account_id = p_account_id;
  v_prefix := 'manual:' || v_cycle || ':';

  -- Validate EVERYTHING first: a refused payload writes nothing.
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lineas) LOOP
    IF jsonb_typeof(v_line) <> 'object' THEN
      RAISE EXCEPTION 'every line must be an object' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'position') IS DISTINCT FROM 'number' OR (v_line ->> 'position') !~ '^[0-9]{1,6}$' OR (v_line ->> 'position')::integer < 1 THEN
      RAISE EXCEPTION 'every line needs a position (a positive whole number)' USING ERRCODE = '22023';
    END IF;
    v_pos := (v_line ->> 'position')::integer;
    IF v_pos = ANY (v_seen) THEN
      RAISE EXCEPTION 'position % appears twice', v_pos USING ERRCODE = '22023';
    END IF;
    v_seen := v_seen || v_pos;

    IF jsonb_typeof(v_line -> 'customer') IS DISTINCT FROM 'string' OR char_length(btrim(v_line ->> 'customer')) NOT BETWEEN 1 AND 240 THEN
      RAISE EXCEPTION 'line %: customer is required (1 to 240 characters)', v_pos USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'service') IS DISTINCT FROM 'string' OR NOT (v_line ->> 'service') = ANY (c_services) THEN
      RAISE EXCEPTION 'line %: unknown service', v_pos USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'currency') IS DISTINCT FROM 'string' OR char_length(v_line ->> 'currency') NOT BETWEEN 1 AND 12 THEN
      RAISE EXCEPTION 'line %: currency is required (1 to 12 characters)', v_pos USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'amount') IS DISTINCT FROM 'number' OR (v_line ->> 'amount')::numeric <= 0 OR (v_line ->> 'amount')::numeric >= 1e15 THEN
      RAISE EXCEPTION 'line %: amount must be a number above zero', v_pos USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'facturado_gyd') IS DISTINCT FROM 'number' OR (v_line ->> 'facturado_gyd')::numeric < 0 OR (v_line ->> 'facturado_gyd')::numeric >= 1e15
       OR jsonb_typeof(v_line -> 'invertido_gyd') IS DISTINCT FROM 'number' OR (v_line ->> 'invertido_gyd')::numeric < 0 OR (v_line ->> 'invertido_gyd')::numeric >= 1e15
       OR jsonb_typeof(v_line -> 'retorno_gyd') IS DISTINCT FROM 'number' OR abs((v_line ->> 'retorno_gyd')::numeric) >= 1e15 THEN
      RAISE EXCEPTION 'line %: facturado and invertido must be numbers of zero or more, retorno a number', v_pos USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'date') IS DISTINCT FROM 'string' OR (v_line ->> 'date') !~ '^\d{4}-\d{2}-\d{2}$' THEN
      RAISE EXCEPTION 'line %: date must be YYYY-MM-DD', v_pos USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_date := (v_line ->> 'date')::date;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'line %: date is not a valid day', v_pos USING ERRCODE = '22023';
    END;
    IF v_date > v_today + 1 OR v_date < v_today - 400 THEN
      RAISE EXCEPTION 'line %: date out of range', v_pos USING ERRCODE = '22023';
    END IF;
    IF v_line ? 'day_label' AND jsonb_typeof(v_line -> 'day_label') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'line %: day_label must be text', v_pos USING ERRCODE = '22023';
    END IF;
    IF v_line ? 'raw_line' AND jsonb_typeof(v_line -> 'raw_line') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'line %: raw_line must be text', v_pos USING ERRCODE = '22023';
    END IF;
  END LOOP;

  PERFORM set_config('wacrm.calculator_manual_sync', 'true', true);

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lineas) LOOP
    v_pos := (v_line ->> 'position')::integer;
    v_keys := v_keys || (v_prefix || v_pos);
    v_date := (v_line ->> 'date')::date;

    INSERT INTO remittance_calculator_entries (
      account_id, source, status, operation_id, entry_date, day_label, customer_name, service, amount, amount_currency,
      facturado_gyd, invertido_gyd, retorno_gyd, actor_user_id, source_event_id, completed_at, line_position, raw_line
    ) VALUES (
      p_account_id, 'manual', 'completed', NULL, v_date, nullif(left(v_line ->> 'day_label', 120), ''), btrim(v_line ->> 'customer'),
      v_line ->> 'service', (v_line ->> 'amount')::numeric, v_line ->> 'currency',
      (v_line ->> 'facturado_gyd')::numeric, (v_line ->> 'invertido_gyd')::numeric, (v_line ->> 'retorno_gyd')::numeric,
      auth.uid(), v_prefix || v_pos,
      -- midday of the line's Guyana day, so the close files it on that day whatever the viewer's zone
      (v_date + time '12:00') AT TIME ZONE 'America/Guyana', v_pos, nullif(left(v_line ->> 'raw_line', 1000), '')
    )
    ON CONFLICT (account_id, source_event_id) WHERE source_event_id IS NOT NULL
    DO UPDATE SET
      entry_date      = EXCLUDED.entry_date,
      day_label       = EXCLUDED.day_label,
      customer_name   = EXCLUDED.customer_name,
      service         = EXCLUDED.service,
      amount          = EXCLUDED.amount,
      amount_currency = EXCLUDED.amount_currency,
      facturado_gyd   = EXCLUDED.facturado_gyd,
      invertido_gyd   = EXCLUDED.invertido_gyd,
      retorno_gyd     = EXCLUDED.retorno_gyd,
      actor_user_id   = EXCLUDED.actor_user_id,
      completed_at    = EXCLUDED.completed_at,
      line_position   = EXCLUDED.line_position,
      raw_line        = EXCLUDED.raw_line
    -- only a row that really changed is written (a repeated sync leaves the very same rows)
    WHERE remittance_calculator_entries.source = 'manual'
      AND (remittance_calculator_entries.entry_date, remittance_calculator_entries.day_label, remittance_calculator_entries.customer_name,
           remittance_calculator_entries.service, remittance_calculator_entries.amount, remittance_calculator_entries.amount_currency,
           remittance_calculator_entries.facturado_gyd, remittance_calculator_entries.invertido_gyd, remittance_calculator_entries.retorno_gyd,
           remittance_calculator_entries.raw_line)
          IS DISTINCT FROM
          (EXCLUDED.entry_date, EXCLUDED.day_label, EXCLUDED.customer_name, EXCLUDED.service, EXCLUDED.amount, EXCLUDED.amount_currency,
           EXCLUDED.facturado_gyd, EXCLUDED.invertido_gyd, EXCLUDED.retorno_gyd, EXCLUDED.raw_line);
  END LOOP;

  -- The lines no longer in the text leave the ledger (this week's rows only: the key space of the cycle).
  DELETE FROM remittance_calculator_entries e
   WHERE e.account_id = p_account_id AND e.source = 'manual'
     AND left(e.source_event_id, char_length(v_prefix)) = v_prefix
     AND NOT (e.source_event_id = ANY (v_keys));

  PERFORM set_config('wacrm.calculator_manual_sync', '', true);

  SELECT jsonb_build_object('count', count(*),
                            'facturado_gyd', coalesce(sum(facturado_gyd), 0),
                            'invertido_gyd', coalesce(sum(invertido_gyd), 0),
                            'retorno_gyd',   coalesce(sum(retorno_gyd), 0))
    INTO v_tot
    FROM remittance_calculator_entries
   WHERE account_id = p_account_id AND source = 'manual' AND left(source_event_id, char_length(v_prefix)) = v_prefix;

  RETURN v_tot;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('wacrm.calculator_manual_sync', '', true);
  RAISE;
END;
$function$;

REVOKE ALL ON FUNCTION public.crm_sincronizar_entradas_manuales(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_sincronizar_entradas_manuales(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION public.crm_sincronizar_entradas_manuales(uuid, jsonb) IS
  'Agent+ only. Replaces the account''s manual Calculator entries of the CURRENT week (since the last weekly cut) with the '
  'parsed lines the client sends; idempotent; a refused payload writes nothing. Entries of a closed week are never touched.';

CREATE OR REPLACE FUNCTION public.remittance_calculator_entries_lock_completed()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_correcting boolean := coalesce(current_setting('wacrm.calculator_correction', true), '') = 'true';
  -- (228) crm_sincronizar_entradas_manuales is the ONLY caller ever allowed to set this GUC, for the duration of its own
  -- statements. It may insert, update and delete MANUAL rows; it never opens a chat-fed row.
  v_syncing    boolean := coalesce(current_setting('wacrm.calculator_manual_sync', true), '') = 'true';
BEGIN
  -- (228) a manual row (a line typed in the Calculator) changes only through the sync RPC.
  IF TG_OP = 'DELETE' THEN
    IF OLD.source = 'manual' THEN
      IF v_syncing THEN RETURN OLD; END IF;
      RAISE EXCEPTION 'remittance_calculator_entries: a manual row changes only through the Calculator sync'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF OLD.source = 'manual' OR NEW.source = 'manual' THEN
    IF v_syncing AND OLD.source = 'manual' AND NEW.source = 'manual' THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'remittance_calculator_entries: a manual row changes only through the Calculator sync'
      USING ERRCODE = 'insufficient_privilege';
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
