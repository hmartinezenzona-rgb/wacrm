-- =====================================================================
-- 194 — A Cuban phone sent during a cash delivery is the cash recipient's phone, not a card (staging first)
--
-- odd/tasks/remesa-closing-and-cash.md (P1 finding). Owner test on staging, 2026-10-03 18:23 UTC: in a cash delivery
-- (efectivo_usd) the customer sent the recipient's phone alone. 'Registrar beneficiario auto' ->
-- cerebro_guardar_beneficiario_auto saved it as a cuban_card beneficiary without card (a second vigente row, so
-- crm_beneficiarios_completos read the remesa incomplete although name, phone, address and ID were there) and returned
-- "FALTA: la tarjeta. Pideselo al cliente." to the agent. Now, when the resolved open remesa is efectivo_usd and no card
-- came in the burst, the phone goes to crm_registrar_datos_entrega_efectivo (merge, audit, kept name/address/ID) and
-- the agent is told what the cash delivery still lacks. Every other case is unchanged.
--
-- Guarded by supabase/staging/assertions/cash-phone-not-a-card.sql.
-- ROLLBACK: ROLLBACK-194-cash-phone-not-a-card.sql
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario_auto(p_conv uuid, p_tarjeta text, p_celular text, p_tarjeta_acum text, p_celular_acum text, p_exec text)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t text := cerebro_norm_tarjeta(p_tarjeta);
  v_c text := cerebro_norm_celular_cu(p_celular);
  v_ta text := cerebro_norm_tarjeta(p_tarjeta_acum);
  v_ca text := cerebro_norm_celular_cu(p_celular_acum);
  v_res record; v_out record;
  v_cash jsonb;
  v_falta text;
BEGIN
  SELECT * INTO v_res FROM cerebro_resolver_operacion_beneficiario(p_conv,
           ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'],
           coalesce(NULLIF(v_t, '!'), NULLIF(v_ta, '!'), ''));
  -- (194) A CASH delivery has no card: a Cuban phone arriving alone is the cash recipient's phone. It used to be
  -- saved as a cuban_card beneficiary without card (a second vigente row: the remesa read incomplete) and the agent
  -- was told to ask for a card. A real card in the burst still goes the card way below.
  IF v_res.operation_id IS NOT NULL
     AND (SELECT o.delivery_method FROM remittance_operations o WHERE o.id = v_res.operation_id) = 'efectivo_usd'
     AND coalesce(NULLIF(v_t, '!'), '') = '' THEN
    IF v_c IS NULL OR v_c = '!' THEN
      RETURN QUERY SELECT v_res.operation_id, 'entrega en efectivo: no llego ningun celular valido de quien recibe'::text; RETURN;
    END IF;
    v_cash := crm_registrar_datos_entrega_efectivo(p_conv, v_c, NULL, NULL);
    v_falta := array_to_string(array_remove(ARRAY[
                 CASE WHEN v_cash ->> 'address' IS NULL THEN 'la direccion' END,
                 CASE WHEN v_cash ->> 'id_photo_wamid' IS NULL THEN 'la foto del carnet' END], NULL), ' y ');
    RETURN QUERY SELECT v_res.operation_id,
      ('guardado: celular ' || v_c || ' de quien recibe la entrega en efectivo.'
       || CASE WHEN v_falta = '' THEN ' Datos de la entrega completos.' ELSE ' FALTA: ' || v_falta || '. Pideselo al cliente.' END)::text;
    RETURN;
  END IF;
  IF v_res.operation_id IS NOT NULL THEN
    -- An open remesa: what arrived in this burst, partial, D1 (179).
    SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', coalesce(p_tarjeta, ''), coalesce(p_celular, ''), p_exec, v_res.operation_id, 'Registrar beneficiario auto');
  ELSIF v_res.resultado = 'ninguna' THEN
    -- No open remesa: only the complete pair opens one (as before).
    IF v_ta IS NOT NULL AND v_ta <> '!' AND v_ca IS NOT NULL AND v_ca <> '!' THEN
      SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', v_ta, v_ca, p_exec, NULL, 'Registrar beneficiario auto');
    ELSE
      RETURN QUERY SELECT NULL::uuid, 'sin envio abierto: se espera el dato que falta para abrirlo'::text; RETURN;
    END IF;
  ELSE
    -- Several open remesas the resolver cannot tell apart: the 179 path derives to a person.
    SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', coalesce(p_tarjeta, ''), coalesce(p_celular, ''), p_exec, NULL, 'Registrar beneficiario auto');
  END IF;
  IF v_out.accion LIKE '%Completo.%' THEN
    DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = p_conv;
  END IF;
  RETURN QUERY SELECT v_out.deal_id, v_out.accion;
END $function$;
