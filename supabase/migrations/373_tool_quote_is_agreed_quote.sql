-- 373 -- A quote computed by a calculator tool is stored as the conversation's agreed quote (said = saved).
--
-- Until now the agreed quote (cerebro_cotizacion: read by cerebro_cotizacion_vigente -> cerebro_objetivo_minimo / cerebro_aplicar_cotizacion, and by the
-- panel "Cotizado" line, crm_cotizacion_de_conversacion) was written only by trg_registrar_cotizacion, which parses the bot's reply (cerebro_monto_cotizado).
-- ~25-30 phrasings a month are missed ("Por Zelle son *X GYD*", "Total a depositar: *25,400 GYD*", "*N CUP* por *N GYD*"), leaving a stale quote or none.
-- The four calculator nodes (calcular_envio, calcular_inverso, calcular_usd, calcular_usd_desde_gyd) and cerebro_cotizar already call
-- cerebro_registrar_via_cotizada(conv, tool, via, execution, origin GYD) after cerebro_registrar_cotizacion, so no n8n change is needed: that function now also
-- stores the quote (_cerebro_cotizacion_acordar):
--   * gyd = the GYD the tool computed; while a split is planned (cerebro_reparto_planeado) it is the plan total, like the objective (372);
--   * texto = 'Cotizado por la herramienta <tool>: *<destination> <CUP|USD>*' (the panel line reads that shape); ejecucion = the n8n execution (new column);
--   * the newest write wins, so a tool quote replaces an older parsed one, and a later parsed reply still overwrites it (text parser kept as fallback);
--   * a COMPARISON (two different services quoted in one execution) is not an agreement: the quote this execution stored is removed, and so is an
--     objective calcular_usd fixed for one of those amounts in the same turn (no plan);
--   * no service (via) or no GYD origin (calcular_envio/inverso in a non-GYD currency): nothing stored, as the via row itself is skipped.
-- Everything else is the live body (read 2026-11-13). Rollback: ROLLBACK-373-tool-quote-is-agreed-quote.sql (drops the helper and the column).

ALTER TABLE public.cerebro_cotizacion ADD COLUMN IF NOT EXISTS ejecucion text;
COMMENT ON COLUMN public.cerebro_cotizacion.ejecucion IS '373: the n8n execution whose calculator tool stored this quote; NULL when the text parser stored it.';

CREATE OR REPLACE FUNCTION public._cerebro_cotizacion_acordar(p_conv uuid, p_herramienta text, p_exec text, p_origen_gyd numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_vias  integer;
  v_t0    timestamptz;
  v_plan  numeric;
  v_dest  numeric;
  v_mon   text;
  v_texto text;
BEGIN
  IF p_conv IS NULL OR p_exec IS NULL OR p_origen_gyd IS NULL OR p_origen_gyd <= 0 THEN
    RETURN;
  END IF;

  SELECT count(DISTINCT l.arguments ->> 1), min(l.created_at) INTO v_vias, v_t0
    FROM tool_execution_log l
   WHERE l.execution_id = p_exec AND l.conversation_id = p_conv
     AND l.tool_name IN ('calcular_envio', 'calcular_inverso', 'calcular_usd', 'calcular_usd_desde_gyd')
     AND jsonb_typeof(l.arguments -> 0) = 'number';

  SELECT pl.total_gyd INTO v_plan FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = p_conv;

  IF v_vias >= 2 THEN
    -- Two services quoted in one turn: the customer has not chosen. Nothing agreed, no objective from this turn's quotes.
    DELETE FROM cerebro_cotizacion WHERE conversation_id = p_conv AND ejecucion = p_exec;
    IF v_plan IS NULL THEN
      DELETE FROM cerebro_objetivo_envio o
       WHERE o.conversation_id = p_conv AND o.cerrado_en IS NULL
         AND o.fijado_en >= v_t0 - interval '2 minutes'
         AND o.monto IN (SELECT (l.arguments ->> 0)::numeric FROM tool_execution_log l
                          WHERE l.execution_id = p_exec AND l.conversation_id = p_conv
                            AND l.tool_name IN ('calcular_envio', 'calcular_inverso', 'calcular_usd', 'calcular_usd_desde_gyd')
                            AND jsonb_typeof(l.arguments -> 0) = 'number');
    END IF;
    RETURN;
  END IF;

  -- the destination the tool just recorded (the panel shows "<destination> -> <GYD>"); not shown for a plan total
  IF v_plan IS NULL THEN
    SELECT q.destino_monto, q.destino_moneda INTO v_dest, v_mon
      FROM cerebro_ultima_cotizacion q
     WHERE q.conversation_id = p_conv AND q.herramienta = p_herramienta AND q.cotizado_en > now() - interval '1 minute'
     ORDER BY q.cotizado_en DESC LIMIT 1;
  END IF;
  v_texto := 'Cotizado por la herramienta ' || p_herramienta
             || CASE WHEN v_dest IS NOT NULL THEN ': *' || rtrim(trim(to_char(v_dest, 'FM999,999,999,990.99')), '.') || ' ' || v_mon || '*' ELSE '' END;

  INSERT INTO cerebro_cotizacion (conversation_id, gyd, texto, cotizado_en, ejecucion)
  VALUES (p_conv, coalesce(v_plan, p_origen_gyd), v_texto, now(), p_exec)
  ON CONFLICT (conversation_id) DO UPDATE
    SET gyd = EXCLUDED.gyd, texto = EXCLUDED.texto, cotizado_en = EXCLUDED.cotizado_en, ejecucion = EXCLUDED.ejecucion;
  PERFORM cerebro_aplicar_cotizacion(p_conv);
END $function$;
REVOKE ALL ON FUNCTION public._cerebro_cotizacion_acordar(uuid, text, text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._cerebro_cotizacion_acordar(uuid, text, text, numeric) TO service_role;

CREATE OR REPLACE FUNCTION public.cerebro_registrar_via_cotizada(p_conv uuid, p_herramienta text, p_via text, p_execution_id text, p_origen_gyd numeric DEFAULT NULL::numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_via  text := cerebro_servicio_normalizar(p_via);
  v_exec text := nullif(btrim(coalesce(p_execution_id, '')), '');
BEGIN
  -- No via, no execution, no conversation: no evidence, nothing to record. Never fails the quote tool.
  IF p_conv IS NULL OR v_via IS NULL OR v_exec IS NULL OR p_herramienta IS NULL THEN
    RETURN;
  END IF;
  BEGIN
    INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, arguments, outcome, created_at)
    VALUES (v_exec || ':cotizar:' || p_herramienta || ':' || md5(v_via || clock_timestamp()::text), p_herramienta, v_exec, p_conv,
            jsonb_build_array(to_jsonb(p_origen_gyd), to_jsonb(v_via)),
            CASE WHEN v_via IN ('zelle', 'clasica', 'tropical', 'cuban_card', 'efectivo_usd') THEN v_via ELSE 'otra_via' END,
            clock_timestamp());
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] cerebro_registrar_via_cotizada failed for conversation % (%): %', p_conv, SQLSTATE, SQLERRM;
  END;
  -- (373) said = saved: the quote the tool computed becomes the conversation's agreed quote. Never fails the quote tool.
  BEGIN
    PERFORM _cerebro_cotizacion_acordar(p_conv, p_herramienta, v_exec, p_origen_gyd);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] _cerebro_cotizacion_acordar failed for conversation % (%): %', p_conv, SQLSTATE, SQLERRM;
  END;
END $function$;
