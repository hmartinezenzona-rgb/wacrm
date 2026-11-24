-- Rollback of 390: restores the 360 bodies of the guard and the writer (live staging bodies before 390) and drops the helpers.

CREATE OR REPLACE FUNCTION public.cerebro_guardia_envio_nuevo(p_conv uuid, p_tarjetas text[], p_celulares text[], p_cuentas text[])
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_desde timestamptz; v_horas int; v_mismo boolean;
BEGIN
  -- An open operation exists: the writers' behavior is unchanged.
  IF EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')) THEN
    RETURN NULL;
  END IF;
  v_desde := _cerebro_completada_reciente(p_conv);
  IF v_desde IS NULL THEN RETURN NULL; END IF;   -- outside the window (or never completed): unchanged
  v_horas := greatest(0, round(extract(epoch FROM now() - v_desde) / 3600)::int);

  -- Rule A: the data belongs to a send completed within the window.
  SELECT EXISTS (
    SELECT 1 FROM remittance_operations o JOIN remittance_beneficiaries b ON b.operation_id = o.id
     WHERE o.conversation_id = p_conv AND o.status = 'completed'
       AND coalesce(o.completed_at, o.status_changed_at, o.updated_at) = v_desde
       AND ((b.zelle_account IS NOT NULL AND lower(b.zelle_account) = ANY (ARRAY(SELECT lower(x) FROM unnest(p_cuentas) x WHERE x IS NOT NULL AND x <> '' AND x <> '!')))
         OR (b.card_number IS NOT NULL AND b.card_number = ANY (ARRAY(SELECT x FROM unnest(p_tarjetas) x WHERE x IS NOT NULL AND x <> '' AND x <> '!')))
         OR (b.phone IS NOT NULL AND b.phone = ANY (ARRAY(SELECT x FROM unnest(p_celulares) x WHERE x IS NOT NULL AND x <> '' AND x <> '!'))))
  ) INTO v_mismo;
  -- Owner decision 2026-11-08: rule A yields only to an explicit send intent newer than the completion (declared service, pending
  -- rail, registered deposit); a quote or an agreed amount alone does not (when in doubt, ask).
  IF v_mismo THEN
    IF _cerebro_senal_envio_nuevo(p_conv, v_desde, true) THEN RETURN NULL; END IF;
    RETURN 'NO SE GUARDO NADA y no se abrio ningun envio: esos datos son del envio que ya se completo hace ' || v_horas
           || ' h. Dile al cliente que ese envio ya esta completo. Solo si quiere hacer OTRO envio, preguntaselo y que diga el servicio y el monto.';
  END IF;

  -- Rule B: a send just completed and nothing says the customer wants another one.
  IF NOT _cerebro_senal_envio_nuevo(p_conv, v_desde) THEN
    RETURN 'NO SE ABRIO NINGUN ENVIO: el ultimo envio de este cliente se completo hace ' || v_horas
           || ' h y no hay ningun envio nuevo en marcha (ni servicio declarado, ni cotizacion, ni deposito). No se guardo nada. Preguntale al cliente'
           || ' si quiere hacer un envio nuevo; si lo quiere, que diga el servicio y el monto y entonces guarda los datos.';
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_escribir_bloque_beneficiario(p_conv uuid, p_op uuid, p_bloque text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op      uuid := p_op;
  v_bi      integer;
  v_reparto boolean;
  v_zelle   integer;
  v_locked  boolean;
  v_account uuid;
BEGIN
  -- (210) A combo's recipients are written only by crm_registrar_destinatario_combo: this remesa writer (typed numbers,
  -- the remesa tools) neither writes on a combo nor opens a remesa next to an open combo. Owner test 2026-10-04: typed
  -- phones became 'cuban_card' generations on the combo and its recipients turned 'reemplazado'.
  -- (223) Nor ON a mobile balance (its one phone recipient is written from the panel only): a typed card is a remesa.
  -- (213) Never ON a visa (it has no recipients at all) nor on a combo past collecting its recipients (its deposit
  -- arrived): the typed data is a new remesa, opened next to it. Only a combo still collecting keeps the numbers (210).
  IF v_op IS NOT NULL AND EXISTS (SELECT 1 FROM remittance_operations o WHERE o.id = v_op
                                   AND (o.service_type IN ('visa', 'saldo')
                                        OR (o.service_type = 'combo' AND o.status <> 'collecting_information'))) THEN
    v_op := cerebro_crear_operacion(p_conv);
    PERFORM _cerebro_auditar_envio_abierto(v_op, 'next to a visa / mobile balance / combo past its recipients');
  ELSIF v_op IS NULL THEN
    SELECT o.id INTO v_op FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status = 'collecting_information'
     ORDER BY o.created_at DESC LIMIT 1;
    IF v_op IS NOT NULL THEN RETURN v_op; END IF;
    v_op := cerebro_crear_operacion(p_conv);
    PERFORM _cerebro_auditar_envio_abierto(v_op, 'nothing open and nothing declared');
  END IF;
  IF (SELECT o.service_type FROM remittance_operations o WHERE o.id = v_op) = 'combo' THEN
    RETURN v_op;
  END IF;

  SELECT admin_locked_fields ? 'beneficiaries', account_id INTO v_locked, v_account
    FROM remittance_operations WHERE id = v_op;
  IF v_locked THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason)
    VALUES (v_account, 'remittance_beneficiaries', v_op, 'beneficiaries', 'automation_write_suppressed',
            wacrm_current_actor(), 'beneficiaries locked by operator correction');
    RETURN v_op;
  END IF;

  SELECT coalesce(max(b.block_index), 0) + 1 INTO v_bi FROM remittance_beneficiaries b WHERE b.operation_id = v_op;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone,
                                        zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular, p.cuenta_zelle, p.monto, p.moneda, p.posicion, v_bi,
         'notes_parse', 'vigente'
    FROM cerebro_parsear_beneficiarios(p_bloque) p;

  -- (175) The newest generation is a reparto between cards: the latest Zelle stays vigente next to it.
  v_reparto := EXISTS (SELECT 1 FROM remittance_beneficiaries
                        WHERE operation_id = v_op AND block_index = v_bi
                          AND beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical'));
  IF v_reparto THEN
    SELECT max(block_index) INTO v_zelle FROM remittance_beneficiaries
     WHERE operation_id = v_op AND beneficiary_type = 'zelle' AND block_index < v_bi;
  END IF;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_bi AND status <> 'reemplazado'
     AND block_index IS DISTINCT FROM v_zelle;

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND block_index = v_zelle AND beneficiary_type = 'zelle' AND status <> 'vigente';

  RETURN v_op;
END $function$;

DROP FUNCTION IF EXISTS public._cerebro_conversacion_pausada(uuid);
DROP FUNCTION IF EXISTS public._cerebro_texto_pausada();
