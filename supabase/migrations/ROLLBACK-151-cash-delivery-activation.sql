-- =====================================================================
-- ROLLBACK 151 — undo the cash-delivery activation.
--
-- Restores cerebro_sync_benef_trigger to the LIVE pre-151 body (Clasica|Tropical
-- only, last mark wins; byte-identical to production's prosrc, md5 ac2d34c4...)
-- and crm_registrar_datos_entrega_efectivo to 150's body (no notification).
-- Operations already marked delivery_method = 'efectivo_usd' keep that
-- value: it is real data, same policy as every other rollback here.
-- 'entrega_efectivo_lista' stays allowed in notifications_type_check while
-- any notification row already uses it (same policy as 127/149/150's own
-- rollbacks); drop it from the CHECK only after those rows are archived.
-- =====================================================================



CREATE OR REPLACE FUNCTION cerebro_sync_benef_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_usd text; v_tipo text;
BEGIN
  IF NEW.pipeline_id <> '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid
     OR NEW.conversation_id IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM cerebro_sync_beneficiarios(NEW.id);

  -- "ENTREGA EN USD: Clasica|Tropical" no es un beneficiario: es como se
  -- entrega. Va a la operacion. Se coge la ULTIMA marca de las notas.
  v_usd := (regexp_match(NEW.notes, 'ENTREGA EN USD: (Clasica|Tropical)(?!.*ENTREGA EN USD)'))[1];
  IF v_usd IS NULL THEN
    SELECT (regexp_matches(NEW.notes, 'ENTREGA EN USD: (Clasica|Tropical)', 'g'))[1]
      INTO v_usd ORDER BY 1 DESC LIMIT 1;
  END IF;

  SELECT b.beneficiary_type INTO v_tipo
    FROM remittance_beneficiaries b
    JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.deal_id = NEW.id AND b.status = 'vigente'
   LIMIT 1;

  UPDATE remittance_operations o
     SET delivery_method = coalesce(lower(v_usd), v_tipo, o.delivery_method)
   WHERE o.deal_id = NEW.id
     AND o.delivery_method IS DISTINCT FROM coalesce(lower(v_usd), v_tipo, o.delivery_method);

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] sync beneficiarios fallo para deal % : %', NEW.id, SQLERRM;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION crm_registrar_datos_entrega_efectivo(
  p_conv           uuid,
  p_phone          text DEFAULT NULL,
  p_address        text DEFAULT NULL,
  p_id_photo_wamid text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op_id       uuid;
  v_account_id  uuid;
  v_existing    remittance_beneficiaries%ROWTYPE;
  v_row         remittance_beneficiaries%ROWTYPE;
  v_new_phone   text;
  v_new_address text;
  v_new_photo   text;
  v_changed     boolean;
  v_next_block  integer;
BEGIN
  IF p_conv IS NULL THEN
    RAISE EXCEPTION 'conversation id is required' USING ERRCODE = '22023';
  END IF;

  -- The one open efectivo_usd remesa for this conversation. This RPC
  -- never creates an operation: if none matches, it is wrong to call it
  -- at all (there is nothing to record the data against).
  SELECT o.id, o.account_id INTO v_op_id, v_account_id
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.service_type = 'remesa'
     AND o.delivery_method = 'efectivo_usd'
     AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC
   LIMIT 1
   FOR UPDATE;

  IF v_op_id IS NULL THEN
    RAISE EXCEPTION 'no open cash-delivery (efectivo_usd) operation for this conversation'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing
    FROM remittance_beneficiaries
   WHERE operation_id = v_op_id AND beneficiary_type = 'efectivo_usd' AND status = 'vigente'
   LIMIT 1;

  -- MERGE: NULL means "no new value this call" — this is the whole
  -- mechanism that lets the bot call this once per turn without ever
  -- losing a field a previous turn already recorded.
  v_new_phone   := coalesce(p_phone, v_existing.phone);
  v_new_address := coalesce(p_address, v_existing.address);
  v_new_photo   := coalesce(p_id_photo_wamid, v_existing.id_photo_wamid);

  -- No-op guard: only write when the merged values actually differ from
  -- what is already stored. With no prior row, "differ" means at least
  -- one parameter carries a real value — calling this with everything
  -- NULL and nothing on file yet must not create an empty row either.
  IF v_existing.id IS NOT NULL THEN
    v_changed := v_new_phone   IS DISTINCT FROM v_existing.phone
              OR v_new_address IS DISTINCT FROM v_existing.address
              OR v_new_photo   IS DISTINCT FROM v_existing.id_photo_wamid;
  ELSE
    v_changed := p_phone IS NOT NULL OR p_address IS NOT NULL OR p_id_photo_wamid IS NOT NULL;
  END IF;

  IF NOT v_changed THEN
    v_row := v_existing;
  ELSE
    IF v_existing.id IS NOT NULL THEN
      UPDATE remittance_beneficiaries
         SET status = 'reemplazado', replaced_at = now()
       WHERE id = v_existing.id;
    END IF;

    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block
      FROM remittance_beneficiaries WHERE operation_id = v_op_id;

    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, phone, address, id_photo_wamid,
      position, status, source, block_index
    ) VALUES (
      v_op_id, 'efectivo_usd', v_new_phone, v_new_address, v_new_photo,
      1, 'vigente', 'reparto_auto', v_next_block
    ) RETURNING * INTO v_row;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_row.id, 'phone,address,id_photo_wamid',
            'automation_cash_delivery_data_registered', wacrm_current_actor(),
            CASE WHEN v_existing.id IS NULL THEN NULL ELSE
              jsonb_build_object('phone', v_existing.phone, 'address', v_existing.address, 'id_photo_wamid', v_existing.id_photo_wamid)
            END,
            jsonb_build_object('phone', v_row.phone, 'address', v_row.address, 'id_photo_wamid', v_row.id_photo_wamid));
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'phone', v_row.phone,
    'address', v_row.address,
    'id_photo_wamid', v_row.id_photo_wamid,
    'complete', (v_row.phone IS NOT NULL AND v_row.address IS NOT NULL AND v_row.id_photo_wamid IS NOT NULL),
    'changed', v_changed
  );
END $$;

REVOKE EXECUTE ON FUNCTION crm_registrar_datos_entrega_efectivo(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION crm_registrar_datos_entrega_efectivo(uuid, text, text, text) TO service_role;

NOTIFY pgrst, 'reload schema';
