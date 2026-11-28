-- =====================================================================
-- ROLLBACK 148 — restore cerebro_fijar_objetivo without the commitment
-- guard (075's version, byte-identical body)
--
-- Restores the unconditional behavior: any call from calcular_usd sets
-- the target regardless of beneficiary/receipt presence. The A3 bug
-- returns.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_fijar_objetivo(
  p_conv   uuid,
  p_monto  numeric,
  p_moneda text DEFAULT 'GYD')
RETURNS TABLE(objetivo_gyd numeric, pedido text, accion text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_mon    text;
  v_gyd    numeric;
  v_pedido text;
  v_tasa   numeric;
  v_previo numeric;
  v_cerrado timestamptz;
  v_accion text;
BEGIN
  v_mon := lower(COALESCE(NULLIF(trim(p_moneda), ''), 'gyd'));

  IF p_monto IS NULL OR p_monto <= 0 THEN
    RETURN QUERY SELECT NULL::numeric, NULL::text,
      'NO se fijo nada: el importe no es valido'::text; RETURN;
  END IF;

  IF v_mon = 'gyd' THEN
    v_gyd    := round(p_monto);
    v_pedido := rtrim(trim(to_char(v_gyd,'FM999,999,999,990.99')),'.') || ' GYD';
  ELSIF v_mon = 'usd' THEN
    SELECT t.tasa_cup INTO v_tasa FROM tasas t
     WHERE t.moneda = 'usd' ORDER BY t.fecha DESC, t.actualizada_at DESC LIMIT 1;
    IF v_tasa IS NULL THEN
      RETURN QUERY SELECT NULL::numeric, NULL::text,
        'NO se fijo nada: no hay tasa de USD'::text; RETURN;
    END IF;
    v_gyd    := round(floor(p_monto) * v_tasa);
    v_pedido := rtrim(trim(to_char(floor(p_monto),'FM999,999,999,990')),'.') || ' USD';
  ELSE
    RETURN QUERY SELECT NULL::numeric, NULL::text,
      ('NO se fijo nada: moneda no soportada (' || p_moneda || '). Solo GYD o USD')::text; RETURN;
  END IF;

  SELECT o.monto, o.cerrado_en INTO v_previo, v_cerrado
    FROM cerebro_objetivo_envio o WHERE o.conversation_id = p_conv;

  IF v_previo IS NULL THEN
    v_accion := 'objetivo fijado';
  ELSIF v_cerrado IS NOT NULL THEN
    v_accion := 'envio nuevo: el anterior ya se completo';
  ELSIF v_previo = v_gyd THEN
    v_accion := 'sin cambios, ya estaba fijado';
  ELSE
    v_accion := 'objetivo sustituido (antes '
                || rtrim(trim(to_char(v_previo,'FM999,999,999,990.99')),'.') || ' GYD)';
  END IF;

  INSERT INTO cerebro_objetivo_envio AS o (conversation_id, monto, moneda, pedido)
  VALUES (p_conv, v_gyd, 'GYD', v_pedido)
  ON CONFLICT (conversation_id) DO UPDATE
     SET monto      = EXCLUDED.monto,
         moneda     = 'GYD',
         pedido     = EXCLUDED.pedido,
         fijado_en  = now(),
         deal_id    = CASE WHEN o.cerrado_en IS NOT NULL THEN NULL ELSE o.deal_id END,
         cerrado_en = NULL;

  RETURN QUERY SELECT v_gyd, v_pedido, v_accion;
END;
$function$;
