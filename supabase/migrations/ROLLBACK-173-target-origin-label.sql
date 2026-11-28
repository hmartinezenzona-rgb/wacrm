-- ROLLBACK for 173: restores 170's cerebro_minimo_gyd and 171's cerebro_objetivo_minimo, drops cerebro_riel_op.

CREATE OR REPLACE FUNCTION public.cerebro_minimo_gyd(p_op uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op   remittance_operations%ROWTYPE;
  v_riel text;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_op;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_op.service_type = 'recarga' THEN
    RETURN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200);
  END IF;

  v_riel := COALESCE(
    NULLIF(v_op.delivery_method, ''),
    (SELECT b.beneficiary_type FROM remittance_beneficiaries b
      WHERE b.operation_id = v_op.id AND b.status = 'vigente' ORDER BY b.position LIMIT 1),
    (SELECT p.tipo FROM cerebro_destino_pendiente p
      WHERE p.conversation_id = v_op.conversation_id AND p.actualizado > now() - interval '24 hours'),
    (SELECT CASE WHEN NULLIF(bp.zelle_cuenta, '') IS NOT NULL THEN 'zelle'
                 WHEN NULLIF(bp.tarjeta, '') IS NOT NULL THEN 'cuban_card' END
       FROM cerebro_beneficiario_parcial bp
      WHERE bp.conversation_id = v_op.conversation_id AND bp.actualizado > now() - interval '24 hours'));

  RETURN CASE
    WHEN v_riel IN ('zelle', 'clasica', 'tropical')
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'efectivo_usd'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_efectivo_usd'), '')::numeric, 29000)
    ELSE COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000)
  END;
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op   uuid;
  v_tot  numeric;
  v_meta numeric;
  v_obj  numeric;
  v_hay  boolean;
BEGIN
  SELECT o.id, o.quoted_source_amount INTO v_op, v_tot FROM remittance_operations o WHERE o.deal_id = p_deal;
  IF v_op IS NULL THEN RETURN NULL; END IF;
  -- The latest quote is the target; without one, an objetivo already open (e.g. from
  -- calcular_usd) is kept, never lowered to the bare minimum.
  v_meta := greatest(cerebro_minimo_gyd(v_op),
                     COALESCE(cerebro_cotizacion_vigente(p_conv),
                              (SELECT x.monto FROM cerebro_objetivo_envio x
                                WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL),
                              0));
  -- Another deal of this conversation is already waiting on its own objetivo: leave it alone.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio x
              WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL
                AND x.deal_id IS NOT NULL AND x.deal_id <> p_deal) THEN
    RETURN NULL;
  END IF;
  v_hay := EXISTS (SELECT 1 FROM cerebro_objetivo_envio x WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL);
  -- Covered and nothing open to correct: nothing to do.
  IF v_tot >= v_meta AND NOT p_siempre AND NOT v_hay THEN RETURN NULL; END IF;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido)
  VALUES (p_conv, greatest(v_meta, CASE WHEN p_siempre THEN v_tot ELSE 0 END), 'GYD', now(), p_deal, NULL, 'objetivo del envio (171)')
  ON CONFLICT (conversation_id) DO UPDATE SET
    monto      = EXCLUDED.monto,
    moneda     = 'GYD',
    deal_id    = p_deal,
    pedido     = EXCLUDED.pedido,
    fijado_en  = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.fijado_en ELSE now() END,
    cerrado_en = NULL
  RETURNING monto INTO v_obj;
  RETURN v_obj;
END $$;

DROP FUNCTION IF EXISTS public.cerebro_riel_op(uuid);
