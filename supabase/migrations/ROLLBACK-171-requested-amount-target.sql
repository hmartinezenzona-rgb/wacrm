-- ROLLBACK for 171: drops the quote trigger and its functions/table and restores 170's
-- cerebro_objetivo_minimo (service minimum only). Objetivos already written stay.

DROP TRIGGER IF EXISTS trg_registrar_cotizacion ON public.messages;
DROP FUNCTION IF EXISTS public.cerebro_registrar_cotizacion();
DROP FUNCTION IF EXISTS public.cerebro_aplicar_cotizacion(uuid);

CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op  uuid;
  v_tot numeric;
  v_min numeric;
  v_obj numeric;
BEGIN
  SELECT o.id, o.quoted_source_amount INTO v_op, v_tot FROM remittance_operations o WHERE o.deal_id = p_deal;
  IF v_op IS NULL THEN RETURN NULL; END IF;
  v_min := cerebro_minimo_gyd(v_op);
  IF v_tot >= v_min AND NOT p_siempre THEN RETURN NULL; END IF;
  -- Another deal of this conversation is already waiting on its own objetivo: leave it alone.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio x
              WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL
                AND x.deal_id IS NOT NULL AND x.deal_id <> p_deal) THEN
    RETURN NULL;
  END IF;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido)
  VALUES (p_conv, greatest(v_min, v_tot), 'GYD', now(), p_deal, NULL, 'minimo del servicio (170)')
  ON CONFLICT (conversation_id) DO UPDATE SET
    monto      = greatest(CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.monto ELSE 0 END,
                          EXCLUDED.monto),
    moneda     = 'GYD',
    deal_id    = p_deal,
    pedido     = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.pedido ELSE EXCLUDED.pedido END,
    fijado_en  = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.fijado_en ELSE now() END,
    cerrado_en = NULL
  RETURNING monto INTO v_obj;
  RETURN v_obj;
END $$;

DROP FUNCTION IF EXISTS public.cerebro_cotizacion_vigente(uuid);
DROP FUNCTION IF EXISTS public.cerebro_monto_cotizado(text);
DROP TABLE IF EXISTS public.cerebro_cotizacion;
DELETE FROM cerebro_config WHERE clave = 'cotizacion_ventana_horas';
