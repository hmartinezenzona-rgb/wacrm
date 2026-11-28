-- 382: an agent attaches an image of the chat as a receipt of an operation (T3a of odd/tasks/panel-fully-editable.md).
--
-- Owner, 2026-11-17: "si falto por algun motivo el comprobante ... poder elegir del chat la imagen del comprobante". Case 78e3540b (same day): the
-- customer sent a new receipt in a burst of three images; the system kept one, so the others never became a receipt of any operation.
--
-- Attaching only STORES the image as a receipt of the operation: a row in remittance_operation_receipts (source 'admin') and the mapping the panel
-- uses to show the image (comprobantes_hashes: comp_id -> the message; an image the bot already hashed keeps its comp_id). The reference (digits)
-- and the amount are the ones typed, or else the ones of the system's own reading of that image (cerebro_lecturas_vision, tipo comprobante)
-- when there is one. It does not verify anything: the card's verify crosses the reference and amount with the MMG ledger as always.
-- The image must be an image message of the operation's conversation. Audit action human_receipt_attached.
--
-- The receipts table only accepts the sources it lists ('admin' is added) and the audit table the actions it lists (the list of staging after 381
-- plus the new one).

ALTER TABLE public.remittance_operation_receipts DROP CONSTRAINT IF EXISTS remittance_operation_receipts_source_chk;
ALTER TABLE public.remittance_operation_receipts ADD CONSTRAINT remittance_operation_receipts_source_chk CHECK (source = ANY (ARRAY['bot'::text, 'backfill'::text, 'admin'::text]));

ALTER TABLE public.remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE public.remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk CHECK (action = ANY (ARRAY[
  'automation_write_suppressed'::text,
  'automation_completion_suppressed'::text,
  'automation_revert_suppressed'::text,
  'human_correction'::text,
  'human_reassignment'::text,
  'human_deposit_verification'::text,
  'human_forced_verification'::text,
  'human_delivery'::text,
  'calculator_feed_failed'::text,
  'calculator_pending_resolved'::text,
  'human_beneficiary_added'::text,
  'automation_reparto_registered'::text,
  'human_calculator_correction'::text,
  'automation_cash_delivery_data_registered'::text,
  'automation_late_deposit_verification'::text,
  'human_manual_close'::text,
  'human_operation_deleted'::text,
  'automation_recharge_numbers_registered'::text,
  'automation_combo_recipient_registered'::text,
  'human_combo_cost_set'::text,
  'automation_visa_registered'::text,
  'human_calculator_entry_deleted'::text,
  'human_calculator_manual_added'::text,
  'automation_service_change'::text,
  'automation_mixed_split'::text,
  'agent_service_change'::text,
  'agent_mexico_recipient_registered'::text,
  'agent_amount_change'::text,
  'agent_operation_cancel'::text,
  'agent_operation_merge'::text,
  'agent_recharge_number_removed'::text,
  'agent_beneficiary_corrected'::text,
  'agent_deposit_move'::text,
  'human_beneficiary_removed'::text,
  'human_operation_created'::text,
  'human_status_change'::text,
  'human_deposit_move'::text,
  'human_deposit_release'::text,
  'human_receipt_attached'::text
]));

CREATE OR REPLACE FUNCTION public.crm_adjuntar_comprobante(p_operation_id uuid, p_wamid text, p_ref text DEFAULT NULL, p_monto numeric DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_acc    uuid;
  v_conv   uuid;
  v_status text;
  v_wamid  text := btrim(coalesce(p_wamid, ''));
  v_msg    messages%ROWTYPE;
  v_lec    cerebro_lecturas_vision%ROWTYPE;
  v_comp   text;
  v_phone  text;
  v_typed  text := nullif(btrim(coalesce(p_ref, '')), '');
  v_ref    text;
  v_monto  numeric;
  v_pref   boolean := false;
BEGIN
  SELECT account_id, conversation_id, status INTO v_acc, v_conv, v_status FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_acc, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to attach a receipt to this operation' USING ERRCODE = '42501';
  END IF;
  IF v_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;
  IF p_monto IS NOT NULL AND p_monto <= 0 THEN
    RAISE EXCEPTION 'amount must be greater than 0' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_msg FROM messages m
   WHERE m.message_id = v_wamid AND m.content_type = 'image' AND m.conversation_id = v_conv LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wamid must be the message id of an image of this conversation' USING ERRCODE = '22023';
  END IF;

  -- The system's own reading of that image, when it read it as a receipt.
  SELECT * INTO v_lec FROM cerebro_lecturas_vision l
   WHERE l.conversation_id = v_conv AND l.wamid = v_wamid AND l.tipo = 'comprobante' ORDER BY l.creado DESC LIMIT 1;

  v_ref := nullif(regexp_replace(coalesce(v_typed, v_lec.referencia, ''), '[^0-9]', '', 'g'), '');
  v_monto := coalesce(p_monto, v_lec.monto);
  v_pref := (v_typed IS NULL AND v_ref IS NOT NULL) OR (p_monto IS NULL AND v_monto IS NOT NULL);

  -- The image keeps the comp_id the bot gave it; otherwise it gets one and the mapping the panel reads.
  SELECT ch.comp_id INTO v_comp FROM comprobantes_hashes ch
   WHERE (ch.whatsapp_message_id = v_wamid OR ch.ultimo_reenvio_wamid = v_wamid) AND ch.comp_id IS NOT NULL
   ORDER BY ch.fecha_recibido LIMIT 1;
  IF v_comp IS NULL THEN
    v_comp := 'COMP-' || left(md5(v_wamid), 7);
    SELECT ct.phone INTO v_phone FROM conversations cv JOIN contacts ct ON ct.id = cv.contact_id WHERE cv.id = v_conv;
    INSERT INTO comprobantes_hashes (hash_imagen, cliente_whatsapp, comp_id, fecha_recibido, whatsapp_message_id)
    VALUES ('admin-' || md5(v_wamid), coalesce(v_phone, ''), v_comp, coalesce(v_msg.created_at, now()), v_wamid)
    ON CONFLICT (hash_imagen) DO NOTHING;
  END IF;

  IF EXISTS (SELECT 1 FROM remittance_operation_receipts r WHERE r.operation_id = p_operation_id AND r.comp_id = v_comp) THEN
    RAISE EXCEPTION 'this image is already a receipt of the operation' USING ERRCODE = '22023';
  END IF;

  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, receipt_status, reference, source)
  VALUES (p_operation_id, v_conv, v_comp, v_monto, CASE WHEN v_monto IS NULL THEN NULL ELSE coalesce(v_lec.moneda, 'GYD') END,
          coalesce(v_lec.estado, 'DESCONOCIDO'), v_ref, 'admin');

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_acc, 'remittance_operations', p_operation_id, 'receipt', 'human_receipt_attached', wacrm_current_actor(), NULL,
          jsonb_build_object('wamid', v_wamid, 'comp_id', v_comp, 'reference', v_ref, 'amount', v_monto, 'prefilled', v_pref));

  RETURN jsonb_build_object('comp_id', v_comp, 'reference', v_ref, 'amount', v_monto, 'prefilled', v_pref);
END $function$;

REVOKE ALL ON FUNCTION public.crm_adjuntar_comprobante(uuid, text, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_adjuntar_comprobante(uuid, text, text, numeric) TO authenticated;
