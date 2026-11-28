-- 342 -- Cash delivery (efectivo_usd) supports several recipients, one per position.
-- crm_registrar_datos_entrega_efectivo updates the recipient at p_posicion
-- (default 1, the previous single-recipient behaviour) and stores p_monto as that
-- recipient's USD amount. Data may arrive in any order: each call completes or
-- corrects one slot, and the completeness notice is per slot. Signature gains two
-- optional parameters; existing callers keep working.

CREATE OR REPLACE FUNCTION public.crm_registrar_datos_entrega_efectivo(p_conv uuid, p_phone text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_id_photo_wamid text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_posicion integer DEFAULT NULL::integer, p_monto numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op_id       uuid;
  v_account_id  uuid;
  v_existing    remittance_beneficiaries%ROWTYPE;
  v_row         remittance_beneficiaries%ROWTYPE;
  v_new_phone   text;
  v_new_address text;
  v_new_photo   text;
  v_new_name    text;
  v_changed     boolean;
  v_next_block  integer;
  v_was_complete boolean;
  v_is_complete  boolean;
  v_cliente     text;
  v_pos         integer;
  v_new_amount  numeric;
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
    -- (275) The agent declared efectivo_usd and no operation exists yet: it opens now (0 GYD, awaiting its deposit).
    IF _cerebro_operacion_declarada(p_conv, 'efectivo_usd', 'agent:registrar_datos_entrega_efectivo') IS NOT NULL THEN
      SELECT o.id, o.account_id INTO v_op_id, v_account_id
        FROM remittance_operations o
       WHERE o.conversation_id = p_conv AND o.service_type = 'remesa' AND o.delivery_method = 'efectivo_usd'
         AND o.status NOT IN ('completed', 'cancelled')
       ORDER BY o.created_at DESC LIMIT 1
       FOR UPDATE;
    END IF;
  END IF;

  IF v_op_id IS NULL THEN
    RAISE EXCEPTION 'no open cash-delivery (efectivo_usd) operation for this conversation'
      USING ERRCODE = '22023';
  END IF;

  -- (342) One cash recipient per position; without a position the single/first one, as before.
  v_pos := coalesce(p_posicion, 1);

  SELECT * INTO v_existing
    FROM remittance_beneficiaries
   WHERE operation_id = v_op_id AND beneficiary_type = 'efectivo_usd' AND status = 'vigente'
     AND position = v_pos
   LIMIT 1;

  v_new_phone   := coalesce(p_phone, v_existing.phone);
  v_new_address := coalesce(p_address, v_existing.address);
  v_new_photo   := coalesce(p_id_photo_wamid, v_existing.id_photo_wamid);
  -- (191) The recipient's name: optional, never required for completeness, kept once given.
  v_new_name    := coalesce(nullif(btrim(p_name), ''), v_existing.name);
  v_new_amount  := coalesce(p_monto, v_existing.amount);

  IF v_existing.id IS NOT NULL THEN
    v_changed := v_new_phone   IS DISTINCT FROM v_existing.phone
              OR v_new_address IS DISTINCT FROM v_existing.address
              OR v_new_photo   IS DISTINCT FROM v_existing.id_photo_wamid
              OR v_new_name    IS DISTINCT FROM v_existing.name
              OR v_new_amount  IS DISTINCT FROM v_existing.amount;
  ELSE
    v_changed := p_phone IS NOT NULL OR p_address IS NOT NULL OR p_id_photo_wamid IS NOT NULL OR v_new_name IS NOT NULL OR p_monto IS NOT NULL;
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
      operation_id, beneficiary_type, name, phone, address, id_photo_wamid,
      position, status, source, block_index, amount, currency
    ) VALUES (
      v_op_id, 'efectivo_usd', v_new_name, v_new_phone, v_new_address, v_new_photo,
      v_pos, 'vigente', 'reparto_auto', v_next_block, v_new_amount,
      CASE WHEN v_new_amount IS NOT NULL THEN 'USD' END
    ) RETURNING * INTO v_row;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_row.id, 'name,phone,address,id_photo_wamid',
            'automation_cash_delivery_data_registered', wacrm_current_actor(),
            CASE WHEN v_existing.id IS NULL THEN NULL ELSE
              jsonb_build_object('name', v_existing.name, 'phone', v_existing.phone, 'address', v_existing.address, 'id_photo_wamid', v_existing.id_photo_wamid)
            END,
            jsonb_build_object('name', v_row.name, 'phone', v_row.phone, 'address', v_row.address, 'id_photo_wamid', v_row.id_photo_wamid));
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
           || coalesce('Nombre: ' || v_row.name || chr(10), '')
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
    'name', v_row.name,
    'phone', v_row.phone,
    'address', v_row.address,
    'id_photo_wamid', v_row.id_photo_wamid,
    'complete', v_is_complete,
    'changed', v_changed,
    'position', v_row.position,
    'amount', v_row.amount
  );
END $function$;

-- The old 5-argument signature would otherwise stay as a second overload and
-- keep serving the 5-argument calls with the single-recipient body.
DROP FUNCTION IF EXISTS public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text, text);

REVOKE ALL ON FUNCTION public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text, text, integer, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text, text, integer, numeric) TO service_role;

-- ROLLBACK: ROLLBACK-342-efectivo-multiples.sql
