-- Rollback of 373: restores cerebro_registrar_via_cotizada to its live production body (read 2026-11-13), drops the helper and the column. Quotes stored stay out with the column.

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
END $function$;

DROP FUNCTION IF EXISTS public._cerebro_cotizacion_acordar(uuid, text, text, numeric);
ALTER TABLE public.cerebro_cotizacion DROP COLUMN IF EXISTS ejecucion;
