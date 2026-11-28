-- =====================================================================
-- 173 — the objetivo records where it came from
--
-- When a remesa waits for the rest, the Cerebro tells the customer "you said
-- you would send X, you have sent Y, Z is missing". Since 170 the target X can
-- be the SERVICE MINIMUM, which the customer never said: 10,000 GYD for a Zelle
-- waits for the 13,000 minimum, and the bot would claim the customer asked for
-- 13,000. The bot needs to know which it is.
--
-- cerebro_objetivo_envio.pedido now says it:
--   'cotizacion'           -> the bot's quote (171): "you asked for X"
--   'minimo <rail>'        -> the service minimum: "the minimum for <rail> is X"
--   anything else          -> kept as it was (e.g. calcular_usd's '200 USD')
-- The Cerebro's `Cruzar deposito con MMG` node returns it as pedido_objetivo.
--
-- cerebro_riel_op(op) is the rail resolution 170 inlined in cerebro_minimo_gyd,
-- now shared by the minimum and the label.
--
-- Guarded by supabase/staging/assertions/target-origin-label.sql
-- ROLLBACK: ROLLBACK-173-target-origin-label.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_riel_op(p_op uuid)
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN o.service_type = 'recarga' THEN 'recarga' ELSE COALESCE(
    NULLIF(o.delivery_method, ''),
    (SELECT b.beneficiary_type FROM remittance_beneficiaries b
      WHERE b.operation_id = o.id AND b.status = 'vigente' ORDER BY b.position LIMIT 1),
    (SELECT p.tipo FROM cerebro_destino_pendiente p
      WHERE p.conversation_id = o.conversation_id AND p.actualizado > now() - interval '24 hours'),
    (SELECT CASE WHEN NULLIF(bp.zelle_cuenta, '') IS NOT NULL THEN 'zelle'
                 WHEN NULLIF(bp.tarjeta, '') IS NOT NULL THEN 'cuban_card' END
       FROM cerebro_beneficiario_parcial bp
      WHERE bp.conversation_id = o.conversation_id AND bp.actualizado > now() - interval '24 hours')) END
    FROM remittance_operations o
   WHERE o.id = p_op;
$$;

CREATE OR REPLACE FUNCTION public.cerebro_minimo_gyd(p_op uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_riel text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = p_op) THEN RETURN NULL; END IF;
  v_riel := cerebro_riel_op(p_op);
  RETURN CASE
    WHEN v_riel = 'recarga'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200)
    WHEN v_riel IN ('zelle', 'clasica', 'tropical')
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'efectivo_usd'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_efectivo_usd'), '')::numeric, 29000)
    ELSE COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000)
  END;
END $$;

-- (173) 171's function; only the pedido it writes changes.
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op     uuid;
  v_tot    numeric;
  v_min    numeric;
  v_cot    numeric;
  v_prev   numeric;
  v_meta   numeric;
  v_pedido text;
  v_obj    numeric;
  v_hay    boolean;
BEGIN
  SELECT o.id, o.quoted_source_amount INTO v_op, v_tot FROM remittance_operations o WHERE o.deal_id = p_deal;
  IF v_op IS NULL THEN RETURN NULL; END IF;
  v_min  := cerebro_minimo_gyd(v_op);
  v_cot  := cerebro_cotizacion_vigente(p_conv);
  v_prev := (SELECT x.monto FROM cerebro_objetivo_envio x WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL);
  -- The latest quote is the target; without one, an objetivo already open (e.g. from
  -- calcular_usd) is kept, never lowered to the bare minimum.
  v_meta := greatest(v_min, COALESCE(v_cot, v_prev, 0));
  -- Where the target came from, for what the bot tells the customer. NULL keeps the
  -- pedido already there (an objetivo set by calcular_usd).
  v_pedido := CASE
    WHEN v_cot IS NOT NULL AND v_cot >= v_min THEN 'cotizacion'
    WHEN v_cot IS NULL AND v_prev IS NOT NULL AND v_prev > v_min THEN NULL
    ELSE 'minimo ' || CASE cerebro_riel_op(v_op)
                        WHEN 'zelle' THEN 'Zelle'
                        WHEN 'clasica' THEN 'Clásica'
                        WHEN 'tropical' THEN 'Tropical'
                        WHEN 'efectivo_usd' THEN 'efectivo en USD'
                        WHEN 'recarga' THEN 'recarga'
                        ELSE 'tarjeta CUP' END
  END;
  -- Another deal of this conversation is already waiting on its own objetivo: leave it alone.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio x
              WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL
                AND x.deal_id IS NOT NULL AND x.deal_id <> p_deal) THEN
    RETURN NULL;
  END IF;
  v_hay := v_prev IS NOT NULL;
  -- Covered and nothing open to correct: nothing to do.
  IF v_tot >= v_meta AND NOT p_siempre AND NOT v_hay THEN RETURN NULL; END IF;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido)
  VALUES (p_conv, greatest(v_meta, CASE WHEN p_siempre THEN v_tot ELSE 0 END), 'GYD', now(), p_deal, NULL,
          COALESCE(v_pedido, 'objetivo del envio'))
  ON CONFLICT (conversation_id) DO UPDATE SET
    monto      = EXCLUDED.monto,
    moneda     = 'GYD',
    deal_id    = p_deal,
    pedido     = COALESCE(v_pedido, cerebro_objetivo_envio.pedido),
    fijado_en  = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.fijado_en ELSE now() END,
    cerrado_en = NULL
  RETURNING monto INTO v_obj;
  RETURN v_obj;
END $$;

REVOKE ALL ON FUNCTION public.cerebro_riel_op(uuid) FROM PUBLIC, anon, authenticated;
