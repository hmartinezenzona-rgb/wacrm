-- =====================================================================
-- 297 -- Automatic USD -> MXN rate (ARQ's own ticker)
--
-- Osmany sets the Mexico payout rate by hand with ARQ, which (owner 2026-10-24) converts at "the same rate you see
-- on Google" and publishes no public API. The ARQ FX calculator does use its own ticker: reading its
-- CurrencyCalculator bundle (2026-10-24) found GET https://api.arqfinance.com/v1/tickers?currencies=MXN, which
-- returns [{"ask":...,"bid":...,"book":"usdc_mxn","date":...}] and is reachable from this database. The value used
-- for a payout is the BID (the business sells USDc for MXN); ask is kept in detalle for transparency.
-- open.er-api.com stays as a daily fallback when ARQ does not answer or returns an invalid payload.
--
-- pg_net is asynchronous and its worker cannot see a request until the transaction that queued it commits, so the
-- fetch and the parse live in TWO cron steps: cerebro_tasa_solicitar (queue the GETs) and cerebro_tasa_procesar
-- (one minute later: read net._http_response, parse, store).
--
-- A later 'manual' row wins, so an operator override in the panel needs no code here.
-- Assertion: supabase/staging/assertions/tasa-usd-mxn.sql. Rollback: ROLLBACK-297-tasa-usd-mxn.sql.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.cerebro_tasas_cambio (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  par           text NOT NULL,
  valor         numeric(14, 6),
  fuente        text NOT NULL,
  obtenida_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  registrada_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  detalle       jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT cerebro_tasas_cambio_par_chk CHECK (par = 'USD_MXN')
);

ALTER TABLE public.cerebro_tasas_cambio DROP CONSTRAINT IF EXISTS cerebro_tasas_cambio_fuente_chk;
ALTER TABLE public.cerebro_tasas_cambio
  ADD CONSTRAINT cerebro_tasas_cambio_fuente_chk CHECK (fuente IN ('arq', 'erapi', 'manual'));

ALTER TABLE public.cerebro_tasas_cambio DROP CONSTRAINT IF EXISTS cerebro_tasas_cambio_valor_chk;
ALTER TABLE public.cerebro_tasas_cambio
  ADD CONSTRAINT cerebro_tasas_cambio_valor_chk CHECK (valor IS NULL OR valor > 0);

CREATE INDEX IF NOT EXISTS cerebro_tasas_cambio_vigente_idx
  ON public.cerebro_tasas_cambio (par, registrada_at DESC) WHERE valor IS NOT NULL;

COMMENT ON TABLE public.cerebro_tasas_cambio IS
  'USD -> MXN rate attempts: one row per processed fetch (source yahoo/erapi) or manual override (source manual). '
  'valor NULL records a failed fetch and never replaces the last good value.';

REVOKE ALL ON TABLE public.cerebro_tasas_cambio FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.cerebro_tasas_solicitudes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fuente       text NOT NULL,
  url          text NOT NULL,
  request_id   bigint,
  pedida_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  procesada_at timestamptz,
  resultado    text,
  CONSTRAINT cerebro_tasas_solicitudes_fuente_chk CHECK (fuente IN ('arq', 'erapi'))
);

CREATE INDEX IF NOT EXISTS cerebro_tasas_solicitudes_pendientes_idx
  ON public.cerebro_tasas_solicitudes (pedida_at) WHERE procesada_at IS NULL;

COMMENT ON TABLE public.cerebro_tasas_solicitudes IS
  'pg_net requests queued by cerebro_tasa_solicitar; cerebro_tasa_procesar consumes them a minute later.';

REVOKE ALL ON TABLE public.cerebro_tasas_solicitudes FROM PUBLIC, anon, authenticated;

-- Parsers: pure and testable with saved payloads.
CREATE OR REPLACE FUNCTION public.cerebro_parsear_tasa_arq(p_json jsonb)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v numeric;
BEGIN
  IF p_json IS NULL OR jsonb_typeof(p_json) <> 'array' OR p_json -> 0 IS NULL THEN
    RETURN NULL;
  END IF;
  IF p_json #>> '{0,book}' IS DISTINCT FROM 'usdc_mxn' THEN
    RETURN NULL;
  END IF;
  v := (p_json #>> '{0,bid}')::numeric;   -- the business sells USDc for MXN: bid
  RETURN CASE WHEN v BETWEEN 5 AND 50 THEN v ELSE NULL END;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_parsear_tasa_erapi(p_json jsonb)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v numeric;
BEGIN
  IF p_json IS NULL OR p_json -> 'rates' ->> 'MXN' IS NULL THEN
    RETURN NULL;
  END IF;
  v := (p_json #>> '{rates,MXN}')::numeric;
  RETURN CASE WHEN v BETWEEN 5 AND 50 THEN v ELSE NULL END;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.cerebro_parsear_tasa_arq(jsonb) IS
  'BID of ARQ''s usdc_mxn ticker (the business sells USDc for MXN), or NULL when the payload or the value is invalid.';
COMMENT ON FUNCTION public.cerebro_parsear_tasa_erapi(jsonb) IS
  'rates.MXN of open.er-api.com, or NULL when the payload or the value is invalid.';

CREATE OR REPLACE FUNCTION public.cerebro_registrar_tasa_usd_mxn(
  p_valor   numeric,
  p_fuente  text DEFAULT 'arq',
  p_detalle jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE sql
AS $function$
  INSERT INTO public.cerebro_tasas_cambio (par, valor, fuente, detalle)
  VALUES ('USD_MXN', p_valor, p_fuente, coalesce(p_detalle, '{}'::jsonb))
  RETURNING id;
$function$;

-- Step 1: queue both GETs. Its own transaction (cron) commits, so pg_net's worker can see them.
CREATE OR REPLACE FUNCTION public.cerebro_tasa_solicitar(
  p_url_arq   text DEFAULT 'https://api.arqfinance.com/v1/tickers?currencies=MXN',
  p_url_erapi text DEFAULT 'https://open.er-api.com/v6/latest/USD'
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $function$
DECLARE
  v_n integer := 0;
BEGIN
  INSERT INTO public.cerebro_tasas_solicitudes (fuente, url, request_id)
  VALUES ('arq', p_url_arq,
          net.http_get(url := p_url_arq,
                       headers := jsonb_build_object(
                         'User-Agent', 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
                         'Accept', 'application/json'),
                       timeout_milliseconds := 10000));
  v_n := v_n + 1;

  INSERT INTO public.cerebro_tasas_solicitudes (fuente, url, request_id)
  VALUES ('erapi', p_url_erapi,
          net.http_get(url := p_url_erapi,
                       headers := jsonb_build_object('Accept', 'application/json'),
                       timeout_milliseconds := 10000));
  RETURN v_n + 1;
END;
$function$;

-- Step 2: one minute later, read the responses, parse, store. Yahoo wins; er-api is used only when Yahoo failed.
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
  v_valor     numeric;
  v_arq       numeric;
  v_detalle   jsonb;
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
    v_detalle := jsonb_build_object('request_id', r.request_id, 'http', v_status,
                                    'error', v_error, 'timed_out', coalesce(v_timed, false));
    IF v_status = 200 THEN
      v_valor := CASE r.fuente
                   WHEN 'arq' THEN public.cerebro_parsear_tasa_arq(v_content::jsonb)
                   ELSE public.cerebro_parsear_tasa_erapi(v_content::jsonb)
                 END;
      IF r.fuente = 'arq' AND v_valor IS NOT NULL THEN
        v_detalle := v_detalle || jsonb_build_object(
          'ask', v_content::jsonb #>> '{0,ask}',
          'bid', v_content::jsonb #>> '{0,bid}',
          'date', v_content::jsonb #>> '{0,date}',
          'book', v_content::jsonb #>> '{0,book}');
      END IF;
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
      v_resultado := 'failed';
    END IF;

    UPDATE public.cerebro_tasas_solicitudes
       SET procesada_at = clock_timestamp(), resultado = v_resultado
     WHERE id = r.id;
  END LOOP;

  RETURN v_arq;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_tasa_usd_mxn()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT valor FROM public.cerebro_tasas_cambio
   WHERE par = 'USD_MXN' AND valor IS NOT NULL
   ORDER BY registrada_at DESC LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_tasa_usd_mxn_info()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT jsonb_build_object(
           'valor', valor,
           'fuente', fuente,
           'obtenida_at', obtenida_at,
           'edad_min', round(extract(epoch FROM (now() - registrada_at)) / 60, 1),
           'ask', detalle ->> 'ask',
           'bid', detalle ->> 'bid',
           'fecha_arq', detalle ->> 'date')
    FROM public.cerebro_tasas_cambio
   WHERE par = 'USD_MXN' AND valor IS NOT NULL
   ORDER BY registrada_at DESC LIMIT 1;
$function$;

COMMENT ON FUNCTION public.cerebro_tasa_usd_mxn() IS
  'Latest non-NULL USD_MXN rate (a manual override inserted later wins).';
COMMENT ON FUNCTION public.cerebro_tasa_usd_mxn_info() IS
  'Value, source and age in minutes of the latest USD_MXN rate. Consumers refuse stale rates by edad_min.';

REVOKE ALL ON FUNCTION public.cerebro_tasa_solicitar(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_tasa_procesar() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_registrar_tasa_usd_mxn(numeric, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_parsear_tasa_arq(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_parsear_tasa_erapi(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_usd_mxn() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_usd_mxn_info() TO authenticated, service_role;

-- Two jobs, refreshed in place when their command changes (pg_cron has no UPDATE).
DO $cron$
DECLARE
  v_solicitar text := 'SELECT public.cerebro_tasa_solicitar()';
  v_procesar  text := 'SELECT public.cerebro_tasa_procesar()';
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'actualizar-tasa-usd-mxn') THEN
    PERFORM cron.unschedule('actualizar-tasa-usd-mxn');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job
              WHERE jobname = 'solicitar-tasa-usd-mxn' AND command IS DISTINCT FROM v_solicitar) THEN
    PERFORM cron.unschedule('solicitar-tasa-usd-mxn');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job
              WHERE jobname = 'procesar-tasa-usd-mxn' AND command IS DISTINCT FROM v_procesar) THEN
    PERFORM cron.unschedule('procesar-tasa-usd-mxn');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'solicitar-tasa-usd-mxn') THEN
    PERFORM cron.schedule('solicitar-tasa-usd-mxn', '*/30 12-22 * * *', v_solicitar);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'procesar-tasa-usd-mxn') THEN
    PERFORM cron.schedule('procesar-tasa-usd-mxn', '2,32 12-22 * * *', v_procesar);
  END IF;
END;
$cron$;
