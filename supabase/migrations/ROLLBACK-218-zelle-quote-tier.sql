-- ROLLBACK of 218_zelle_quote_tier.sql: restores cerebro_zelle_cotizar_op exactly as 217 left it (pg_get_functiondef md5 on staging,
-- 2026-10-05: 343b6c56743fcf25994a95c2d9d55725). The quote is no longer used; only an open USD objective applies. Amounts and
-- entries already written keep their stored figures.
CREATE OR REPLACE FUNCTION public.cerebro_zelle_cotizar_op(p_operation_id uuid, p_gyd numeric)
 RETURNS TABLE(usd numeric, tasa numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_x numeric;
  v_p numeric;
BEGIN
  IF p_gyd IS NULL OR p_gyd <= 0 THEN RETURN; END IF;
  -- The open USD objective of the operation's conversation (cerebro_fijar_objetivo stores pedido '999 USD').
  SELECT replace(substring(e.pedido FROM '^([0-9][0-9,]*) USD$'), ',', '')::numeric INTO v_x
    FROM remittance_operations o
    JOIN cerebro_objetivo_envio e ON e.conversation_id = o.conversation_id
   WHERE o.id = p_operation_id AND e.cerrado_en IS NULL AND e.pedido ~ '^[0-9][0-9,]* USD$';
  IF v_x IS NOT NULL AND v_x > 0 THEN
    v_p := cerebro_tasa_zelle(v_x);
    -- The deposit covers the objective at its own tier price: it lies in [X*p, (X+1)*p), i.e. floor(gyd / p) = X.
    IF v_p > 0 AND floor(p_gyd / v_p) = v_x THEN
      RETURN QUERY SELECT v_x, v_p;
      RETURN;
    END IF;
  END IF;
  RETURN QUERY SELECT z.usd, z.tasa FROM cerebro_zelle_cotizar_gyd(p_gyd) z;
END $function$
;
REVOKE ALL ON FUNCTION public.cerebro_zelle_cotizar_op(uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_zelle_cotizar_op(uuid, numeric) TO service_role;
