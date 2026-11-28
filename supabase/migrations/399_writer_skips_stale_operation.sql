-- 399 -- The recipient writer never targets an operation that can no longer take a deposit.
--
-- Root cause (production 2026-11-25, conversation f0dd06de): the recipient writers target any open remesa of their
-- service. The bot reused an unfunded operation opened on 11-23 for the Zelle recipient and changed its service. When
-- the receipt arrived, 391 refused the deposit on that operation (no money and older than completar_ventana_horas) and
-- created a NEW operation, so the recipient stayed on the old one and the bot asked the customer for data it had
-- already given. The chat ended with two open sends and a human had to finish it.
--
-- Fix: cerebro_escribir_bloque_beneficiario is the single funnel for every recipient writer (Zelle, card, reparto and the
-- auto variants). Before writing, it checks the target with the SAME eligibility 391 applies to the deposit
-- (_cerebro_op_puede_recibir_deposito). An open remesa that holds no money, is not incident, has no locked amount and is
-- older than the window is cancelled (audited agent_operation_cancel) and the write opens a clean operation through the
-- existing "nothing open" branch, which already audits the opening. A paused conversation keeps raising the pause text
-- instead of opening anything (390), and the stale operation is then left untouched.
--
-- Out of scope: the deposit side of 391 is unchanged; the UI/reporting of a cancelled operation is unchanged.
--
-- ROLLBACK-399-writer-skips-stale-operation.sql restores the 390 body and drops the helper.

-- ─── 1. the eligibility helper (391's target rule, read from the writer's side) ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._cerebro_op_puede_recibir_deposito(p_op uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Same predicate as the 391 lookup in cerebro_registrar_deposito: an operation with no money is a deposit target only
  -- while it is younger than completar_ventana_horas. An unknown id returns true so the writer's usual path is unchanged.
  SELECT COALESCE((
    SELECT (COALESCE(o.quoted_source_amount, 0) > 0 AND NOT _cerebro_op_monto_acordado(o.id))
        OR EXISTS (SELECT 1 FROM remittance_operation_receipts r WHERE r.operation_id = o.id)
        OR COALESCE((SELECT s.depositado FROM cerebro_saldo_operacion(o.id) s), 0) > 0
        OR o.status = 'incident'
        OR COALESCE(o.admin_locked_fields, '{}'::jsonb) ? 'quoted_source_amount'
        OR o.created_at > now() - make_interval(hours => COALESCE(NULLIF(cerebro_config_get('completar_ventana_horas'), '')::int, 6))
      FROM remittance_operations o
     WHERE o.id = p_op
  ), true);
$function$;

REVOKE ALL ON FUNCTION public._cerebro_op_puede_recibir_deposito(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- ─── 2. the writer ────────────────────────────────────────────────────────────────────────────────────────────────────
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
  -- (399) Never write recipients on an operation that can no longer take a deposit (see the header). Cancelling it here
  -- keeps the chat with ONE open send: the write then lands on the operation the deposit will join.
  IF v_op IS NOT NULL
     AND EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.id = v_op
                    AND o.service_type = 'remesa'
                    AND o.status IN ('collecting_information', 'deposit_verification', 'ready_to_transfer'))
     AND NOT _cerebro_op_puede_recibir_deposito(v_op) THEN
    IF _cerebro_conversacion_pausada(p_conv) THEN RAISE EXCEPTION '%', _cerebro_texto_pausada(); END IF;
    UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_op;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    SELECT o.account_id, 'remittance_operations', o.id, 'status', 'agent_operation_cancel',
           'automation:recipient_writer',
           'open operation too old to take a deposit: the recipient writer opens a new send',
           jsonb_build_object('status', o.status, 'service', o.service_type,
                              'quoted_source_amount', o.quoted_source_amount, 'created_at', o.created_at),
           jsonb_build_object('status', 'cancelled')
      FROM remittance_operations o WHERE o.id = v_op;
    v_op := NULL;
  END IF;

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
