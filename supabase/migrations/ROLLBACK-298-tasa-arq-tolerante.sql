-- ROLLBACK 298: restores the 297 parser and processor, drops the tolerant helper and the estado reader.
DROP FUNCTION IF EXISTS public.cerebro_tasa_usd_mxn_estado();
DROP FUNCTION IF EXISTS public.cerebro_item_tasa_arq(jsonb);

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
