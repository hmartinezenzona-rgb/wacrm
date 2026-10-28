-- =====================================================================
-- 343 -- A deposit with no service chosen is not measured against the CUP minimum.
--
-- PRODUCTION TEST 2026-10-28 02:10 (conversation f51e0f49): the customer sent
-- a 1,000 GYD receipt and a Cuban mobile, no card. cerebro_objetivo_minimo
-- found no rail yet and fell back to the CUP-card minimum, so the objective
-- became 5,000 GYD labelled 'minimo tarjeta CUP'. The deposit (1,000) then
-- looked 4,000 short, the cross never verified it and the operation ended in
-- incident; the bot was paused.
--
-- The amount decides, not the word: 1,000 GYD is exactly one saldo movil
-- package (360 CUP), and no service has been chosen yet. When the operation
-- has NO rail, the money is below the CUP minimum, it is an exact multiple of
-- the saldo price and no live promo price fits it, the objective is the money
-- itself (pedido 'saldo movil') instead of an invented CUP minimum.
--
-- ROLLBACK: ROLLBACK-343-objetivo-saldo-por-monto.sql
-- Assertion: supabase/staging/assertions/objetivo-saldo-por-monto.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op     uuid := cerebro_resolve_op_id(p_deal);
  v_deal   uuid;
  v_tot    numeric;
  v_min    numeric;
  v_cot    numeric;
  v_prev   numeric;
  v_meta   numeric;
  v_pedido text;
  v_obj    numeric;
  v_hay    boolean;
  v_saldo_objetivo boolean := false;
BEGIN
  SELECT o.deal_id, o.quoted_source_amount INTO v_deal, v_tot FROM remittance_operations o WHERE o.id = v_op;
  IF v_op IS NULL OR NOT FOUND THEN RETURN NULL; END IF;
  v_min  := cerebro_minimo_gyd(v_op);
  v_cot  := cerebro_cotizacion_vigente(p_conv);
  v_prev := (SELECT x.monto FROM cerebro_objetivo_envio x WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL);
  -- (343) No rail yet and the money is exactly one or more saldo packages below the CUP
  -- minimum: the objective is the money, not a CUP-card minimum nobody asked for.
  IF cerebro_riel_op(v_op) IS NULL
     AND coalesce(v_tot, 0) > 0
     AND v_tot < COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000)
     AND coalesce(cerebro_saldo_precio(), 0) > 0
     AND mod(v_tot, cerebro_saldo_precio()) = 0
     AND NOT EXISTS (SELECT 1 FROM cerebro_promo_vigente() pr
                      WHERE coalesce(pr.precio_gyd, 0) > 0
                        AND v_tot >= pr.precio_gyd
                        AND mod(v_tot, pr.precio_gyd) = 0) THEN
    v_min := v_tot;
    v_saldo_objetivo := true;
  END IF;
  v_meta := greatest(v_min, COALESCE(v_cot, v_prev, 0));
  v_pedido := CASE
    WHEN v_saldo_objetivo THEN 'saldo movil'  -- (343)
    WHEN v_cot IS NOT NULL AND v_cot >= v_min THEN 'cotizacion'
    WHEN v_cot IS NULL AND v_prev IS NOT NULL AND v_prev > v_min THEN NULL
    ELSE 'minimo ' || CASE cerebro_riel_op(v_op)
                        WHEN 'zelle' THEN 'Zelle'
                        WHEN 'clasica' THEN 'Clásica'
                        WHEN 'tropical' THEN 'Tropical'
                        WHEN 'efectivo_usd' THEN 'efectivo en USD'
                        WHEN 'recarga' THEN 'recarga'
                        WHEN 'combo' THEN 'combo'  -- (209)
                        WHEN 'visa' THEN 'extension de visa'  -- (213)
                        WHEN 'saldo' THEN 'saldo movil'  -- (223)
                        ELSE 'tarjeta CUP' END
  END;
  -- Another operation of this conversation is already waiting on its own objetivo: leave it alone.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio x
              WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL
                AND x.operation_id IS NOT NULL AND x.operation_id <> v_op) THEN
    RETURN NULL;
  END IF;
  v_hay := v_prev IS NOT NULL;
  IF v_tot >= v_meta AND NOT p_siempre AND NOT v_hay THEN RETURN NULL; END IF;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido, operation_id)
  VALUES (p_conv, greatest(v_meta, CASE WHEN p_siempre THEN v_tot ELSE 0 END), 'GYD', now(), v_deal, NULL,
          COALESCE(v_pedido, 'objetivo del envio'), v_op)
  ON CONFLICT (conversation_id) DO UPDATE SET
    monto        = EXCLUDED.monto,
    moneda       = 'GYD',
    deal_id      = v_deal,
    operation_id = v_op,
    pedido       = COALESCE(v_pedido, cerebro_objetivo_envio.pedido),
    fijado_en    = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.fijado_en ELSE now() END,
    cerrado_en   = NULL
  RETURNING monto INTO v_obj;
  RETURN v_obj;
END $function$;
