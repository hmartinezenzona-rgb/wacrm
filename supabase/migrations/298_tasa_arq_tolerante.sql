-- =====================================================================
-- 298 -- USD -> MXN: tolerate ARQ changing its payload, and say when it did
--
-- The ARQ ticker is a private endpoint (migration 297). If it wraps the item, renames bid to rate/price or adds
-- fields, the old parser returned NULL and the failure looked exactly like a network error until the panel's
-- two-hour warning. This migration:
--   1. unwraps the item from the common containers ([...], {data:[...]}, {tickers:[...]}, {results:[...]}, or the
--      object itself) and reads the value from bid/rate/price/value/sell/venta; `book`, when present, must still be
--      usdc_mxn; the plausible range stays 5..50;
--   2. records WHY an attempt failed (motivo: http | red | formato) and, for a 200 that cannot be parsed, a bounded
--      raw snippet (ARQ's public rate payload, never customer data);
--   3. exposes cerebro_tasa_usd_mxn_estado(): the value the panel shows plus the last ARQ attempt and consecutive
--      ARQ failures, so the panel can warn before the value is two hours old.
--
-- Body and column shape of the table and the two-step cron are unchanged (297).
-- Assertion: supabase/staging/assertions/tasa-usd-mxn-estado.sql. Rollback: ROLLBACK-298-*.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_item_tasa_arq(p_json jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_json IS NULL THEN NULL
    WHEN jsonb_typeof(p_json) = 'array' THEN p_json -> 0
    WHEN jsonb_typeof(p_json) = 'object' AND jsonb_typeof(p_json -> 'data') = 'array' THEN p_json -> 'data' -> 0
    WHEN jsonb_typeof(p_json) = 'object' AND jsonb_typeof(p_json -> 'tickers') = 'array' THEN p_json -> 'tickers' -> 0
    WHEN jsonb_typeof(p_json) = 'object' AND jsonb_typeof(p_json -> 'results') = 'array' THEN p_json -> 'results' -> 0
    WHEN jsonb_typeof(p_json) = 'object' THEN p_json
    ELSE NULL
  END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_parsear_tasa_arq(p_json jsonb)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_item jsonb := public.cerebro_item_tasa_arq(p_json);
  v_book text;
  v_txt  text;
  v      numeric;
  k      text;
BEGIN
  IF v_item IS NULL OR jsonb_typeof(v_item) <> 'object' THEN
    RETURN NULL;
  END IF;

  v_book := lower(coalesce(v_item ->> 'book', ''));
  IF v_book <> '' AND v_book <> 'usdc_mxn' THEN
    RETURN NULL;
  END IF;

  FOREACH k IN ARRAY ARRAY['bid', 'rate', 'price', 'value', 'sell', 'venta'] LOOP
    v_txt := v_item ->> k;
    IF v_txt IS NOT NULL THEN
      BEGIN
        v := v_txt::numeric;
      EXCEPTION WHEN others THEN
        v := NULL;
      END;
      IF v BETWEEN 5 AND 50 THEN
        RETURN v;
      END IF;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.cerebro_item_tasa_arq(jsonb) IS
  'The rate object inside the common ARQ payload shapes (array, data/tickers/results wrapper, or the object itself).';
COMMENT ON FUNCTION public.cerebro_parsear_tasa_arq(jsonb) IS
  'ARQ USD->MXN bid (or rate/price/value/sell/venta) from the common payload shapes; book, when present, must be usdc_mxn.';

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
  v_arq       numeric;
  v_detalle   jsonb;
  v_motivo    text;
  v_resultado text;
BEGIN
  DELETE FROM public.cerebro_tasas_solicitudes
   WHERE procesada_at IS NOT NULL AND procesada_at < now() - interval '7 days';

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

    IF r.fuente = 'erapi' AND v_arq IS NOT NULL THEN
      v_resultado := 'skipped: arq ok';
    ELSIF v_valor IS NOT NULL THEN
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
  'What the panel shows (latest value, source, age, ask/bid, ARQ date) plus the last ARQ attempt, its motivo '
  '(ok/http/red/formato) and how many ARQ attempts have failed since the last good ARQ value.';

REVOKE ALL ON FUNCTION public.cerebro_tasa_usd_mxn_estado() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_usd_mxn_estado() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_item_tasa_arq(jsonb) FROM PUBLIC, anon, authenticated;
