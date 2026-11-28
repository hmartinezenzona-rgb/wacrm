-- =====================================================================
-- 218 -- A quoted USD amount keeps its own tier price (staging first)
--
-- odd/tasks/zelle-tiered-rate.md (T3c). 217 applies a requested USD amount only through an OPEN objective
-- (cerebro_objetivo_envio). In the real flow the bot quotes with calcular_usd BEFORE the customer gives the Zelle account, and
-- cerebro_fijar_objetivo (148/152) refuses to fix an objective until a beneficiary or receipt exists, so no objective is there when
-- the deposit lands. The quote IS recorded (cerebro_registrar_cotizacion -> cerebro_ultima_cotizacion, 153), so the owner's
-- "quote 999 USD = 259,740 GYD, then deposit 259,740" still paid 1,038 @250.
--
-- CHANGED: cerebro_zelle_cotizar_op(p_operation_id, p_gyd). The requested amount X is, in this order:
--   1. the open USD objective of the operation's conversation (as in 217);
--   2. otherwise the conversation's USD quote (cerebro_ultima_cotizacion, destino_moneda 'USD', any tool: calcular_usd and
--      calcular_usd_desde_gyd both write the USD quote and derive it with the same tier rule), provided it is recent as in B1.1
--      (153): younger than 24 hours counted from the operation's creation (a stable bound, so a late completion bills the same
--      amount the beneficiary got) and newer than the last OTHER closed remesa of the conversation (the operation being priced
--      is excluded, otherwise its own completion would discard the quote).
-- Same match rule as 217: X applies at p = cerebro_tasa_zelle(X) only when floor(gyd / p) = X; otherwise (no X, no match) the
-- result is cerebro_zelle_cotizar_gyd(gyd), i.e. exactly 215/216. An objective takes precedence over the quote even when it does
-- not match. The five readers of 217 already call this helper; nothing else is redefined.
--
-- Guarded by supabase/staging/assertions/zelle-quote-tier.sql (plus zelle-objective-tier.sql, zelle-tiered-rate.sql,
-- zelle-tier-prices.sql, still green)
-- ROLLBACK: ROLLBACK-218-zelle-quote-tier.sql
-- =====================================================================

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
  -- 1. The open USD objective of the operation's conversation (cerebro_fijar_objetivo stores pedido '999 USD').
  SELECT replace(substring(e.pedido FROM '^([0-9][0-9,]*) USD$'), ',', '')::numeric INTO v_x
    FROM remittance_operations o
    JOIN cerebro_objetivo_envio e ON e.conversation_id = o.conversation_id
   WHERE o.id = p_operation_id AND e.cerrado_en IS NULL AND e.pedido ~ '^[0-9][0-9,]* USD$';
  -- 2. No open USD objective: the conversation's recent USD quote (153), the one the customer was told before the deposit.
  IF v_x IS NULL THEN
    SELECT q.destino_monto INTO v_x
      FROM remittance_operations o
      JOIN cerebro_ultima_cotizacion q ON q.conversation_id = o.conversation_id AND q.destino_moneda = 'USD'
     WHERE o.id = p_operation_id
       AND q.cotizado_en > o.created_at - interval '24 hours'
       AND q.cotizado_en > COALESCE(
             (SELECT max(COALESCE(o2.completed_at, o2.cancelled_at, o2.created_at))
                FROM remittance_operations o2
               WHERE o2.conversation_id = o.conversation_id
                 AND o2.id <> o.id
                 AND o2.status IN ('completed', 'cancelled')),
             '-infinity'::timestamptz);
  END IF;
  IF v_x IS NOT NULL AND v_x > 0 THEN
    v_p := cerebro_tasa_zelle(v_x);
    -- The deposit covers X at its own tier price: it lies in [X*p, (X+1)*p), i.e. floor(gyd / p) = X.
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
