-- ROLLBACK 154 — restore 153's cerebro_monto_recibe (method-only quote pick).
CREATE OR REPLACE FUNCTION cerebro_monto_recibe(p_conv uuid)
RETURNS TABLE (valor numeric, moneda text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_valor   numeric;
  v_moneda  text;
  v_metodo  text;
  v_quiere  text;
BEGIN
  -- The open remesa's own amount, when it has one (after the deposit).
  SELECT NULLIF(o.quoted_destination_amount, 0), o.destination_currency, o.delivery_method
    INTO v_valor, v_moneda, v_metodo
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC
   LIMIT 1;

  IF v_valor IS NOT NULL AND v_moneda IS NOT NULL THEN
    RETURN QUERY SELECT v_valor, v_moneda;
    RETURN;
  END IF;

  -- Otherwise the last quote in the currency the chosen method delivers.
  v_quiere := CASE WHEN v_metodo = 'cuban_card' THEN 'CUP'
                   WHEN v_metodo IN ('zelle', 'clasica', 'tropical') THEN 'USD'
                   ELSE NULL END;

  RETURN QUERY
  SELECT q.destino_monto, q.destino_moneda
    FROM cerebro_ultima_cotizacion q
   WHERE q.conversation_id = p_conv
     AND q.destino_moneda = v_quiere
     AND q.cotizado_en > now() - interval '24 hours'
     AND q.cotizado_en > COALESCE(
           (SELECT max(COALESCE(o2.completed_at, o2.cancelled_at, o2.created_at))
              FROM remittance_operations o2
             WHERE o2.conversation_id = p_conv
               AND o2.status IN ('completed', 'cancelled')),
           '-infinity'::timestamptz);

  IF NOT FOUND THEN
    RETURN QUERY SELECT NULL::numeric, NULL::text;
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION cerebro_monto_recibe(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_monto_recibe(uuid) TO service_role;
