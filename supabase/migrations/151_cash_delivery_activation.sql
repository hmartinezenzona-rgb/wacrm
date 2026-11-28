-- =====================================================================
-- 151 — Cash USD delivery actually activates, and the admin is told
--        when the recipient's data is complete (B1.4)
--
-- PROBLEM
--   150 gave the efectivo_usd recipient's phone/address/ID photo a place
--   to live, but nothing ever marks an operation as
--   delivery_method = 'efectivo_usd'. marcar_destino_usd (n8n) writes
--   "ENTREGA EN USD: <tipo>" into deals.notes, and cerebro_sync_benef_
--   trigger (042) only parses 'Clasica|Tropical' out of that note. So 150's
--   RPC, the context flags and the ID-photo capture all waited on an
--   operation that could never exist — B1.4 was inert.
--
-- PRODUCT DECISION (user, 2026-09-29): the bot collects the three pieces
--   of data first, then an admin is NOTIFIED. The chat is NOT handed over:
--   the bot keeps attending it. So this is an in-app notification, not
--   derivar_humano / cerebro_registrar_derivacion (which assign the chat
--   and silence the bot).
--
-- FIX
--   1. cerebro_sync_benef_trigger: the note parser also accepts
--      "ENTREGA EN USD: Efectivo" and maps it to 'efectivo_usd' (the value
--      150's RPC and the context flags look for). Clasica/Tropical keep
--      mapping to lower(tipo) exactly as before.
--      BASED ON THE LIVE BODY, NOT 042's: production and staging run an
--      unversioned later edit (identical prosrc md5 on both, ac2d34c4...)
--      that takes the LAST "ENTREGA EN USD" mark in the notes, so a customer
--      can change delivery method. 042's body would have silently dropped
--      that. Every other line is that live body, byte for byte.
--   2. notifications_type_check gains 'entrega_efectivo_lista'. Full list
--      carried forward from the live constraint (identical on production,
--      staging and the rehearsal DB when this was written).
--   3. crm_registrar_datos_entrega_efectivo: 150's body plus ONE addition.
--      When a call turns the recipient from incomplete into complete
--      (phone + address + ID photo all known), it inserts one
--      'entrega_efectivo_lista' notification for each owner/admin of the
--      account. Only on that transition: a later correction to an already
--      complete recipient does not notify again. The frontend needs no
--      change: unknown notification types render with the generic icon,
--      as 8 of the 12 existing types already do.
--
-- ROLLBACK: ROLLBACK-151-cash-delivery-activation.sql
-- Guarded by supabase/staging/assertions/cash-delivery-activation.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The note parser learns "Efectivo".
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cerebro_sync_benef_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_usd text; v_tipo text;
BEGIN
  IF NEW.pipeline_id <> '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid
     OR NEW.conversation_id IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM cerebro_sync_beneficiarios(NEW.id);

  -- "ENTREGA EN USD: Clasica|Tropical|Efectivo" no es un beneficiario: es como
  -- se entrega. Va a la operacion. Se coge la ULTIMA marca de las notas.
  -- (151) Efectivo se guarda como 'efectivo_usd', el valor que buscan la RPC
  -- de la 150 y Contexto conversacion. Clasica/Tropical siguen igual.
  v_usd := (regexp_match(NEW.notes, 'ENTREGA EN USD: (Clasica|Tropical|Efectivo)(?!.*ENTREGA EN USD)'))[1];
  IF v_usd IS NULL THEN
    SELECT (regexp_matches(NEW.notes, 'ENTREGA EN USD: (Clasica|Tropical|Efectivo)', 'g'))[1]
      INTO v_usd ORDER BY 1 DESC LIMIT 1;
  END IF;

  SELECT b.beneficiary_type INTO v_tipo
    FROM remittance_beneficiaries b
    JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.deal_id = NEW.id AND b.status = 'vigente'
   LIMIT 1;

  v_usd := CASE WHEN v_usd = 'Efectivo' THEN 'efectivo_usd' ELSE lower(v_usd) END;

  UPDATE remittance_operations o
     SET delivery_method = coalesce(v_usd, v_tipo, o.delivery_method)
   WHERE o.deal_id = NEW.id
     AND o.delivery_method IS DISTINCT FROM coalesce(v_usd, v_tipo, o.delivery_method);

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] sync beneficiarios fallo para deal % : %', NEW.id, SQLERRM;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------
-- 2. The new notification type.
-- ---------------------------------------------------------------------

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'conversation_assigned',
    'deal_incidencia',
    'mensaje_fallido',
    'promo_etecsa',
    'chat_atascado',
    'ingesta_caida',
    'deposito_sin_cruzar',
    'mensaje_perdido',
    'envio_incompleto',
    'pide_mlc',
    'envio_sin_beneficiario',
    'remesa_abierta_vieja',
    'entrega_efectivo_lista'
  ));

-- ---------------------------------------------------------------------
-- 3. The RPC notifies the admins when the data becomes complete.
-- ---------------------------------------------------------------------

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
  v_was_complete boolean;
  v_is_complete  boolean;
  v_cliente     text;
BEGIN
  IF p_conv IS NULL THEN
    RAISE EXCEPTION 'conversation id is required' USING ERRCODE = '22023';
  END IF;

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

  v_new_phone   := coalesce(p_phone, v_existing.phone);
  v_new_address := coalesce(p_address, v_existing.address);
  v_new_photo   := coalesce(p_id_photo_wamid, v_existing.id_photo_wamid);

  IF v_existing.id IS NOT NULL THEN
    v_changed := v_new_phone   IS DISTINCT FROM v_existing.phone
              OR v_new_address IS DISTINCT FROM v_existing.address
              OR v_new_photo   IS DISTINCT FROM v_existing.id_photo_wamid;
  ELSE
    v_changed := p_phone IS NOT NULL OR p_address IS NOT NULL OR p_id_photo_wamid IS NOT NULL;
  END IF;

  v_was_complete := v_existing.id IS NOT NULL
                AND v_existing.phone IS NOT NULL
                AND v_existing.address IS NOT NULL
                AND v_existing.id_photo_wamid IS NOT NULL;

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

  v_is_complete := v_row.phone IS NOT NULL
               AND v_row.address IS NOT NULL
               AND v_row.id_photo_wamid IS NOT NULL;

  -- (151) Aviso al admin, SOLO en la transicion a completo. El chat NO se
  -- asigna ni se pausa: el bot sigue atendiendo (decision del usuario).
  IF v_is_complete AND NOT v_was_complete THEN
    SELECT coalesce(nullif(c.name, ''), c.phone) || ' (' || c.phone || ')'
      INTO v_cliente
      FROM conversations v JOIN contacts c ON c.id = v.contact_id
     WHERE v.id = p_conv;

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT v_account_id, p.user_id, 'entrega_efectivo_lista',
           'Entrega en efectivo lista para coordinar: ' || coalesce(v_cliente, 'cliente'),
           'El cliente ' || coalesce(v_cliente, '') || ' ya dio los tres datos de quien recibe el efectivo.'
           || chr(10) || chr(10)
           || 'Telefono: ' || v_row.phone || chr(10)
           || 'Direccion: ' || v_row.address || chr(10)
           || 'Foto del carnet: recibida en el chat.'
           || chr(10) || chr(10)
           || 'Falta coordinar zona y horario de la entrega. El bot sigue atendiendo la conversacion.'
      FROM profiles p
     WHERE p.account_id = v_account_id
       AND p.account_role IN ('owner', 'admin')
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'phone', v_row.phone,
    'address', v_row.address,
    'id_photo_wamid', v_row.id_photo_wamid,
    'complete', v_is_complete,
    'changed', v_changed
  );
END $$;

REVOKE EXECUTE ON FUNCTION crm_registrar_datos_entrega_efectivo(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION crm_registrar_datos_entrega_efectivo(uuid, text, text, text) TO service_role;

NOTIFY pgrst, 'reload schema';
