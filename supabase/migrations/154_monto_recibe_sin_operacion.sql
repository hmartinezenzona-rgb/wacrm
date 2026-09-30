-- =====================================================================
-- 154 — Say the recipient amount even when the operation does not exist
--        yet (B1.1 follow-up)
--
-- PROBLEM (real staging test, 2026-09-30): the customer chose CUP, got
--   "Por 10,000 GYD llegan 30,000 CUP", sent card and phone, and the
--   confirmation still had no amount. `Contexto conversacion` runs at the
--   start of the turn, BEFORE the beneficiary is registered in that same
--   turn, so the operation (and its delivery_method) did not exist yet.
--   153 only picked a quote by the operation's method, so it returned NULL.
--
-- CHANGE: cerebro_monto_recibe also returns the quote when the method is not
--   known yet (no open operation, or one with delivery_method NULL) AND only
--   one currency was quoted in the last 24 hours. A double CUP+USD quote with
--   no method is still not guessed (NULL), and a known method that the quote
--   tools don't serve (efectivo_usd) still gets NULL. Everything else is
--   153 unchanged.
--
-- ROLLBACK: ROLLBACK-154-monto-recibe-sin-operacion.sql (restores 153's body)
-- Guarded by supabase/staging/assertions/ultima-cotizacion.sql (case 10)
-- =====================================================================

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
     AND (q.destino_moneda = v_quiere
          -- 154: method not known yet (no operation, or none chosen): the
          -- quote is used only when it is the ONLY currency quoted recently,
          -- so a double CUP+USD quote is still never guessed.
          OR (v_metodo IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM cerebro_ultima_cotizacion q2
                 WHERE q2.conversation_id = p_conv
                   AND q2.destino_moneda <> q.destino_moneda
                   AND q2.cotizado_en > now() - interval '24 hours')))
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
