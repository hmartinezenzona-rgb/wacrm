-- =====================================================================
-- 346 -- No service is invented while the customer has not chosen one.
--
-- The operation already opens without a service (service_type 'remesa',
-- delivery_method NULL) and the panel shows it as "needs service". What still
-- assumed a service was the objective: cerebro_minimo_gyd returns the CUP
-- minimum for a rail-less operation, so a 1,200 GYD deposit got an objective of
-- 5,000 labelled 'minimo tarjeta CUP' and a 3,800 shortfall nobody asked for;
-- exact saldo multiples got 'saldo movil' (343). Both name a service before the
-- customer did.
--
-- Now a rail-less operation takes the deposited money as its objective, with a
-- neutral 'deposito' label. A quote (v_cot) or a previous agreed objective
-- still win, and the minimum is enforced when the service is declared. The
-- card-typed recipient without a card number stops resolving as a card rail
-- (legacy rows; 345 already stops creating them).
--
-- ROLLBACK: ROLLBACK-346-sin-servicio-sin-minimo.sql
-- Assertion: supabase/staging/assertions/sin-servicio-sin-minimo.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_riel_op(p_op uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN o.service_type = 'recarga' THEN 'recarga'
              -- (209) a combo has its own rail (its recipients are 'combo' rows, but it can have none yet)
              WHEN o.service_type = 'combo' THEN 'combo'
              -- (213) a visa has no recipients at all: its own rail
              WHEN o.service_type = 'visa' THEN 'visa'
              -- (223) a mobile balance top-up has its own rail (its recipient is a phone-only 'recarga' row)
              WHEN o.service_type = 'saldo' THEN 'saldo'
              -- (273) a Mexico send has its own rail; its recipients are 'mexico_cuenta' / 'mexico_retiro' rows (delivery_method)
              WHEN o.service_type = 'mexico' THEN 'mexico' ELSE COALESCE(
    NULLIF(o.delivery_method, ''),
    -- (346) A card-typed row without a card number is not a card rail: a lone
    -- Cuban mobile stored as cuban_card must not make the send look like CUP.
    (SELECT b.beneficiary_type FROM remittance_beneficiaries b
      WHERE b.operation_id = o.id AND b.status = 'vigente'
        AND (b.beneficiary_type NOT IN ('cuban_card', 'clasica', 'tropical')
             OR NULLIF(btrim(coalesce(b.card_number, '')), '') IS NOT NULL)
      ORDER BY b.position LIMIT 1),
    (SELECT p.tipo FROM cerebro_destino_pendiente p
      WHERE p.conversation_id = o.conversation_id AND p.actualizado > now() - interval '24 hours'),
    (SELECT CASE WHEN NULLIF(bp.zelle_cuenta, '') IS NOT NULL THEN 'zelle'
                 WHEN NULLIF(bp.tarjeta, '') IS NOT NULL THEN 'cuban_card' END
       FROM cerebro_beneficiario_parcial bp
      WHERE bp.conversation_id = o.conversation_id AND bp.actualizado > now() - interval '24 hours')) END
    FROM remittance_operations o
   WHERE o.id = p_op;
$function$;

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
  v_objetivo_deposito boolean := false;
BEGIN
  SELECT o.deal_id, o.quoted_source_amount INTO v_deal, v_tot FROM remittance_operations o WHERE o.id = v_op;
  IF v_op IS NULL OR NOT FOUND THEN RETURN NULL; END IF;
  v_min  := cerebro_minimo_gyd(v_op);
  v_cot  := cerebro_cotizacion_vigente(p_conv);
  v_prev := (SELECT x.monto FROM cerebro_objetivo_envio x WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL);
  -- (346) A send with no service chosen yet has no minimum: until a service is
  -- declared, the objective is the money deposited, never a card, Zelle or saldo
  -- minimum nobody asked for. The minimum applies when the service is declared
  -- (cerebro_cambiar_servicio / cerebro_resolver_servicio check it there).
  IF cerebro_riel_op(v_op) IS NULL AND coalesce(v_tot, 0) > 0 THEN
    v_min := v_tot;
    v_objetivo_deposito := true;
  END IF;
  v_meta := greatest(v_min, COALESCE(v_cot, v_prev, 0));
  v_pedido := CASE
    WHEN v_objetivo_deposito THEN 'deposito'  -- (346)
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
