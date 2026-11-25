-- ROLLBACK-399 -- restores the 390 body of cerebro_escribir_bloque_beneficiario and drops the eligibility helper.
-- Run with infra/db/staging-migracion.sh rollback; production is reverted by applying this file through the same cycle.
-- The operations 399 cancelled stay cancelled; this rollback does not reopen them.

DROP FUNCTION IF EXISTS public._cerebro_op_puede_recibir_deposito(uuid);

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
    IF _cerebro_conversacion_pausada(p_conv) THEN RAISE EXCEPTION '%', _cerebro_texto_pausada(); END IF;
    v_op := cerebro_crear_operacion(p_conv);
    PERFORM _cerebro_auditar_envio_abierto(v_op, 'next to a visa / mobile balance / combo past its recipients');
  ELSIF v_op IS NULL THEN
    SELECT o.id INTO v_op FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status = 'collecting_information'
     ORDER BY o.created_at DESC LIMIT 1;
    IF v_op IS NOT NULL THEN RETURN v_op; END IF;
    IF _cerebro_conversacion_pausada(p_conv) THEN RAISE EXCEPTION '%', _cerebro_texto_pausada(); END IF;
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
