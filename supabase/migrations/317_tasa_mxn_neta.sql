-- =====================================================================
-- 317 -- The USD-MXN rate is stored and shown NET, the number the client
--        sees in ARQ's app
--
-- Owner decision 2026-10-25: ARQ publishes a gross bid (18.6474810965 on
-- 2026-10-25) but its converter shows 1 USDc = 18.5542 MXN, i.e. the bid
-- minus a 0.5% fee. Costing a Mexico payout on the gross bid overstates what
-- the client receives by 0.5% (about 93 MXN per 1,000 USD). From now on the
-- stored `valor` and everything the panel shows is that NET number.
--
--   * cerebro_config.tasa_mxn_comision_pct = 0.5 (editable without a migration).
--   * cerebro_tasa_mxn_neta(bruto, pct): the pure conversion, so the assertion
--     can prove the arithmetic without HTTP.
--   * cerebro_tasa_procesar: applies it to BOTH sources (arq and the erapi
--     fallback), so a fallback day does not silently jump 0.5% up; the raw
--     value is kept in detalle (bruto, comision_pct) for transparency.
--   * cerebro_tasa_usd_mxn_estado: also returns bruto and comision_pct.
--   * Manual overrides are untouched: a 'manual' row already is the number the
--     operator chose.
--
-- Assertion: supabase/staging/assertions/tasa-mxn-neta.sql.
-- Rollback: ROLLBACK-317-tasa-mxn-neta.sql.
-- =====================================================================

INSERT INTO public.cerebro_config (clave, valor, descripcion)
VALUES ('tasa_mxn_comision_pct', '0.5',
        'Comision que ARQ aplica al convertir USDc a MXN en su app. La tasa guardada es el NETO (bruto x (1 - pct/100)).')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cerebro_tasa_mxn_neta(p_bruto numeric, p_pct numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE WHEN p_bruto IS NULL THEN NULL
              ELSE round(p_bruto * (1 - coalesce(p_pct, 0) / 100), 6) END;
$function$;

COMMENT ON FUNCTION public.cerebro_tasa_mxn_neta(numeric, numeric) IS
  'USD-MXN net rate: the gross rate minus the ARQ fee percentage (317).';

CREATE OR REPLACE FUNCTION public.cerebro_tasa_procesar()
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $function$
DECLARE
  r           record;
  v_status    integer;
  v_content   text;
  v_error     text;
  v_timed     boolean;
  v_item      jsonb;
  v_valor     numeric;
  v_bruto     numeric;
  v_pct       numeric;
  v_arq       numeric;
  v_detalle   jsonb;
  v_motivo    text;
  v_resultado text;
BEGIN
  DELETE FROM public.cerebro_tasas_solicitudes
   WHERE procesada_at IS NOT NULL AND procesada_at < now() - interval '7 days';

  v_pct := coalesce(nullif(public.cerebro_config_get('tasa_mxn_comision_pct'), '')::numeric, 0);

  FOR r IN
    SELECT * FROM public.cerebro_tasas_solicitudes
     WHERE procesada_at IS NULL AND pedida_at > now() - interval '45 minutes'
     ORDER BY (fuente = 'arq') DESC, pedida_at
  LOOP
    SELECT status_code, content, error_msg, timed_out
      INTO v_status, v_content, v_error, v_timed
      FROM net._http_response WHERE id = r.request_id;

    IF NOT FOUND THEN
      CONTINUE;  -- still in flight: leave it pending for the next run
    END IF;

    v_valor := NULL;
    v_bruto := NULL;
    v_motivo := NULL;
    v_detalle := jsonb_build_object('request_id', r.request_id, 'http', v_status,
                                    'error', v_error, 'timed_out', coalesce(v_timed, false));

    IF v_status = 200 THEN
      IF r.fuente = 'arq' THEN
        v_item := public.cerebro_item_tasa_arq(v_content::jsonb);
        v_valor := public.cerebro_parsear_tasa_arq(v_content::jsonb);
        IF v_valor IS NOT NULL THEN
          v_motivo := 'ok';
          v_detalle := v_detalle || jsonb_strip_nulls(jsonb_build_object(
            'ask', v_item ->> 'ask',
            'bid', coalesce(v_item ->> 'bid', v_item ->> 'rate'),
            'date', v_item ->> 'date',
            'book', v_item ->> 'book'));
        ELSE
          v_motivo := 'formato';
          v_detalle := v_detalle || jsonb_build_object('motivo', 'formato', 'raw', left(v_content, 500));
        END IF;
      ELSE
        v_valor := public.cerebro_parsear_tasa_erapi(v_content::jsonb);
        v_motivo := CASE WHEN v_valor IS NULL THEN 'formato' ELSE 'ok' END;
        IF v_valor IS NULL THEN
          v_detalle := v_detalle || jsonb_build_object('motivo', 'formato', 'raw', left(v_content, 500));
        END IF;
      END IF;
    ELSE
      v_motivo := CASE WHEN coalesce(v_timed, false) OR v_error IS NOT NULL THEN 'red' ELSE 'http' END;
      v_detalle := v_detalle || jsonb_build_object('motivo', v_motivo);
    END IF;

    -- (317) What gets stored is the NET the client sees; the gross stays in detalle.
    IF v_valor IS NOT NULL THEN
      v_bruto := v_valor;
      v_valor := public.cerebro_tasa_mxn_neta(v_bruto, v_pct);
      v_detalle := v_detalle || jsonb_build_object('bruto', v_bruto, 'comision_pct', v_pct);
    END IF;

    IF r.fuente = 'erapi' AND v_arq IS NOT NULL THEN
      v_resultado := 'skipped: arq ok';
    ELSIF v_valor IS NOT NULL AND v_valor > 0 THEN
      PERFORM public.cerebro_registrar_tasa_usd_mxn(v_valor, r.fuente, v_detalle);
      v_resultado := 'ok';
      IF r.fuente = 'arq' THEN
        v_arq := v_valor;
      END IF;
    ELSE
      PERFORM public.cerebro_registrar_tasa_usd_mxn(NULL, r.fuente, v_detalle);
      v_resultado := coalesce(v_motivo, 'failed');
    END IF;

    UPDATE public.cerebro_tasas_solicitudes
       SET procesada_at = clock_timestamp(), resultado = v_resultado
     WHERE id = r.id;
  END LOOP;

  RETURN v_arq;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_tasa_usd_mxn_estado()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH ultima AS (
    SELECT valor, fuente, obtenida_at, registrada_at, detalle
      FROM public.cerebro_tasas_cambio
     WHERE par = 'USD_MXN' AND valor IS NOT NULL
     ORDER BY registrada_at DESC LIMIT 1
  ), ultimo_arq AS (
    SELECT valor, registrada_at, detalle
      FROM public.cerebro_tasas_cambio
     WHERE par = 'USD_MXN' AND fuente = 'arq'
     ORDER BY registrada_at DESC LIMIT 1
  ), ultimo_arq_ok AS (
    SELECT max(registrada_at) AS at
      FROM public.cerebro_tasas_cambio
     WHERE par = 'USD_MXN' AND fuente = 'arq' AND valor IS NOT NULL
  )
  SELECT jsonb_build_object(
           'valor', u.valor,
           'fuente', u.fuente,
           'obtenida_at', u.obtenida_at,
           'edad_min', round(extract(epoch FROM (now() - u.registrada_at)) / 60, 1),
           'ask', u.detalle ->> 'ask',
           'bid', u.detalle ->> 'bid',
           'bruto', coalesce(u.detalle ->> 'bruto', u.detalle ->> 'bid', u.detalle ->> 'rate'),
           'comision_pct', coalesce((u.detalle ->> 'comision_pct')::numeric,
                                    nullif(public.cerebro_config_get('tasa_mxn_comision_pct'), '')::numeric),
           'fecha_arq', u.detalle ->> 'date',
           'ultimo_arq_at', a.registrada_at,
           'ultimo_arq_ok', a.valor IS NOT NULL,
           'ultimo_motivo', a.detalle ->> 'motivo',
           'fallos_arq_consecutivos',
             (SELECT count(*) FROM public.cerebro_tasas_cambio f
               WHERE f.par = 'USD_MXN' AND f.fuente = 'arq' AND f.valor IS NULL
                 AND f.registrada_at > coalesce(k.at, '-infinity'::timestamptz)))
    FROM ultima u
    LEFT JOIN ultimo_arq a ON true
    LEFT JOIN ultimo_arq_ok k ON true;
$function$;

COMMENT ON FUNCTION public.cerebro_tasa_usd_mxn_estado() IS
  'What the panel shows (latest NET value, source, age, ask/bid, gross, fee, ARQ date) plus the last ARQ attempt, '
  'its motivo (ok/http/red/formato) and how many ARQ attempts have failed since the last good ARQ value.';

REVOKE ALL ON FUNCTION public.cerebro_tasa_mxn_neta(numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_mxn_neta(numeric, numeric) TO authenticated, service_role;
