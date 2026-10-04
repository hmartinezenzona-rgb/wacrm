-- =====================================================================
-- 208 — The food combo operation: recipients, cost and panel RPCs (staging first)
--
-- odd/tasks/combos-end-to-end.md (T1a). A combo is modeled like a recharge: one operation per conversation with
-- several recipients (owner decision 3), each recipient with full name, phone, address, a reference for how to get
-- there, a second contact phone and an amount of at least 25,000 GYD (decision 4). The bot saves them over several
-- messages; the panel lists, adds to and closes the combo; the admin enters the cost by hand (decision 1).
--   - remittance_beneficiaries: type 'combo'; new columns reference and contact_phone. The recipient's name, phone,
--     address (150) and amount (GYD, in amount/currency) reuse the existing columns;
--   - remittance_operations.combo_costo_gyd: the cost the admin enters (the calculator reads it later, T1b);
--   - crm_registrar_destinatario_combo: the agent's tool (opens the combo, adds or updates ONE recipient; empty
--     arguments never overwrite; the panel lock wins; audited as automation_combo_recipient_registered);
--   - crm_beneficiarios_completos: a combo is complete when every recipient has all five fields and >= 25,000 GYD;
--   - crm_operaciones_de_conversacion (RETURNS TABLE grows by three columns: DROP + CREATE), crm_agregar_beneficiario
--     and crm_cerrar_operacion_manual take combos; crm_set_combo_costo for the admin;
--   - cerebro_servicios 'combos': the bot now collects and takes the payment; products are still chosen by a person.
-- Every other branch of the redefined functions is byte-for-byte the previous body (see the ROLLBACK).
-- Not here (T1b): deposit routing to the combo and the calculator feed.
-- Assertion: supabase/staging/assertions/combo-model.sql. Rollback: ROLLBACK-208-combo-model.sql.
-- =====================================================================
ALTER TABLE public.remittance_beneficiaries DROP CONSTRAINT rb_type_chk;
ALTER TABLE public.remittance_beneficiaries ADD CONSTRAINT rb_type_chk
  CHECK (beneficiary_type = ANY (ARRAY['cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution', 'efectivo_usd', 'recarga', 'combo']));

ALTER TABLE public.remittance_beneficiaries
  ADD COLUMN IF NOT EXISTS reference text,
  ADD COLUMN IF NOT EXISTS contact_phone text;
COMMENT ON COLUMN public.remittance_beneficiaries.reference IS '208. A combo recipient: how to get to the house or what the place looks like.';
COMMENT ON COLUMN public.remittance_beneficiaries.contact_phone IS '208. A combo recipient: the phone of a second contact person, digits only.';

ALTER TABLE public.remittance_operations
  ADD COLUMN IF NOT EXISTS combo_costo_gyd numeric;
ALTER TABLE public.remittance_operations
  ADD CONSTRAINT remittance_operations_combo_costo_chk CHECK (combo_costo_gyd IS NULL OR combo_costo_gyd >= 0);
COMMENT ON COLUMN public.remittance_operations.combo_costo_gyd IS '208. A combo: what it cost, in GYD, entered by hand by an admin (crm_set_combo_costo). NULL until entered.';

ALTER TABLE remittance_admin_audit DROP CONSTRAINT remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action = ANY (ARRAY['automation_write_suppressed', 'automation_completion_suppressed', 'automation_revert_suppressed',
    'human_correction', 'human_reassignment', 'human_deposit_verification', 'human_forced_verification', 'human_delivery',
    'calculator_feed_failed', 'calculator_pending_resolved', 'human_beneficiary_added', 'automation_reparto_registered',
    'human_calculator_correction', 'automation_cash_delivery_data_registered', 'automation_late_deposit_verification',
    'human_manual_close', 'human_operation_deleted',
    'automation_recharge_numbers_registered',
    'automation_combo_recipient_registered', 'human_combo_cost_set']));

CREATE OR REPLACE FUNCTION public.crm_registrar_destinatario_combo(p_conv uuid, p_nombre text, p_telefono text, p_direccion text, p_referencia text, p_telefono_contacto text, p_monto_gyd numeric, p_numero integer DEFAULT NULL)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- (208) The agent's tool for a food combo. Opens the conversation's combo (collecting_information, GYD) when none is
-- open, then adds or updates ONE recipient. p_numero (the combo's number in the order the customer said them, 1-based)
-- picks the recipient at that position, or a new one when there is none yet: owner test 2026-10-04, "dos combos, uno
-- de 30 mil y otro de 25 mil" said before any name, made the second call overwrite the first. Without p_numero:
-- matched by phone, or by name while the stored row has no phone (or the call has none); with neither, the latest
-- recipient. Empty arguments never overwrite what is stored. The panel's
-- beneficiary lock wins. quoted_source_amount = the sum of the recipients' amounts. Returns what is still missing.
DECLARE
  v_op      record;
  v_name    text;
  v_phone   text;
  v_addr    text;
  v_ref     text;
  v_contact text;
  v_monto   numeric;
  v_digits  text;
  v_aviso   text := '';
  v_id      uuid;
  v_pos     int;
  v_block   int;
  v_changed int := 0;
  v_r       record;
  v_n       int := 0;
  v_total   numeric;
  v_falta   text[];
  v_label   text;
  v_msgs    text := '';
  v_bajo    text := '';
BEGIN
  SELECT o.id, o.account_id, o.admin_locked_fields INTO v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC LIMIT 1
   FOR UPDATE;
  IF v_op.id IS NULL THEN
    INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
    SELECT v.account_id, v.id, v.contact_id, 'collecting_information', 'combo', 'GYD', 0
      FROM conversations v WHERE v.id = p_conv
    RETURNING id, account_id, admin_locked_fields INTO v_op;
    IF v_op.id IS NULL THEN
      RETURN 'conversacion no encontrada: no se abre ningun combo';
    END IF;
  END IF;
  IF coalesce(v_op.admin_locked_fields, '{}'::jsonb) ? 'beneficiaries' THEN
    RETURN 'los destinatarios de este combo los gestiona una persona desde el panel: no se cambian';
  END IF;

  v_name := nullif(btrim(regexp_replace(coalesce(p_nombre, ''), '\s+', ' ', 'g')), '');
  v_addr := nullif(btrim(coalesce(p_direccion, '')), '');
  v_ref := nullif(btrim(coalesce(p_referencia, '')), '');
  v_monto := CASE WHEN p_monto_gyd > 0 THEN p_monto_gyd END;
  -- Phones: digits only, without the 53 country code; 8 to 15 digits, or it is not saved and the bot asks again.
  v_digits := regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g');
  IF length(v_digits) = 10 AND left(v_digits, 2) = '53' THEN v_digits := substr(v_digits, 3); END IF;
  IF v_digits ~ '^[0-9]{8,15}$' THEN v_phone := v_digits;
  ELSIF v_digits <> '' THEN v_aviso := v_aviso || ' El telefono ' || btrim(p_telefono) || ' no parece valido (faltan o sobran digitos): no se guardo, pideselo de nuevo.';
  END IF;
  v_digits := regexp_replace(coalesce(p_telefono_contacto, ''), '[^0-9]', '', 'g');
  IF length(v_digits) = 10 AND left(v_digits, 2) = '53' THEN v_digits := substr(v_digits, 3); END IF;
  IF v_digits ~ '^[0-9]{8,15}$' THEN v_contact := v_digits;
  ELSIF v_digits <> '' THEN v_aviso := v_aviso || ' El telefono de contacto ' || btrim(p_telefono_contacto) || ' no parece valido (faltan o sobran digitos): no se guardo, pideselo de nuevo.';
  END IF;

  IF p_numero IS NOT NULL AND p_numero >= 1 THEN
    SELECT b.id INTO v_id FROM remittance_beneficiaries b
     WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo'
     ORDER BY b.position OFFSET p_numero - 1 LIMIT 1;
  ELSIF v_phone IS NOT NULL THEN
    SELECT b.id INTO v_id FROM remittance_beneficiaries b
     WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo' AND b.phone = v_phone
     ORDER BY b.position LIMIT 1;
  END IF;
  IF v_id IS NULL AND p_numero IS NULL AND v_name IS NOT NULL THEN
    SELECT b.id INTO v_id FROM remittance_beneficiaries b
     WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo'
       AND lower(b.name) = lower(v_name) AND (v_phone IS NULL OR b.phone IS NULL)
     ORDER BY b.position LIMIT 1;
  END IF;
  IF v_id IS NULL AND p_numero IS NULL AND v_name IS NULL AND v_phone IS NULL THEN
    SELECT b.id INTO v_id FROM remittance_beneficiaries b
     WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo'
     ORDER BY b.position DESC LIMIT 1;
  END IF;

  IF coalesce(v_name, v_phone, v_addr, v_ref, v_contact) IS NOT NULL OR v_monto IS NOT NULL THEN
    IF v_id IS NULL THEN
      SELECT coalesce(max(position), 0) + 1 INTO v_pos FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente';
      SELECT coalesce(max(block_index), 0) + 1 INTO v_block FROM remittance_beneficiaries WHERE operation_id = v_op.id;
      INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, address, reference, contact_phone,
                                            amount, currency, amount_origin, position, block_index, source, status)
      VALUES (v_op.id, 'combo', v_name, v_phone, v_addr, v_ref, v_contact,
              v_monto, 'GYD', CASE WHEN v_monto IS NULL THEN NULL ELSE 'manual' END, v_pos, v_block, 'reparto_auto', 'vigente')
      RETURNING id INTO v_id;
      v_changed := 1;
    ELSE
      UPDATE remittance_beneficiaries b
         SET name = coalesce(v_name, b.name), phone = coalesce(v_phone, b.phone), address = coalesce(v_addr, b.address),
             reference = coalesce(v_ref, b.reference), contact_phone = coalesce(v_contact, b.contact_phone),
             amount = coalesce(v_monto, b.amount),
             currency = CASE WHEN coalesce(v_monto, b.amount) IS NULL THEN b.currency ELSE 'GYD' END,
             amount_origin = CASE WHEN coalesce(v_monto, b.amount) IS NULL THEN b.amount_origin ELSE 'manual' END
       WHERE b.id = v_id
         AND (b.name IS DISTINCT FROM coalesce(v_name, b.name) OR b.phone IS DISTINCT FROM coalesce(v_phone, b.phone)
              OR b.address IS DISTINCT FROM coalesce(v_addr, b.address) OR b.reference IS DISTINCT FROM coalesce(v_ref, b.reference)
              OR b.contact_phone IS DISTINCT FROM coalesce(v_contact, b.contact_phone)
              OR b.amount IS DISTINCT FROM coalesce(v_monto, b.amount));
      GET DIAGNOSTICS v_changed = ROW_COUNT;
    END IF;
  END IF;

  SELECT coalesce(sum(b.amount), 0) INTO v_total FROM remittance_beneficiaries b
   WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo';
  UPDATE remittance_operations SET quoted_source_amount = v_total
   WHERE id = v_op.id AND quoted_source_amount IS DISTINCT FROM v_total;

  IF v_changed > 0 THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'combo_recipient', 'automation_combo_recipient_registered',
            wacrm_current_actor(), NULL,
            jsonb_strip_nulls(jsonb_build_object('recipient_id', v_id, 'name', v_name, 'phone', v_phone, 'address', v_addr,
                                                 'reference', v_ref, 'contact_phone', v_contact, 'amount', v_monto)));
  END IF;

  FOR v_r IN SELECT b.* FROM remittance_beneficiaries b
              WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo'
              ORDER BY b.position LOOP
    v_n := v_n + 1;
    v_label := coalesce(nullif(btrim(coalesce(v_r.name, '')), ''), 'destinatario ' || v_n);
    v_falta := ARRAY[]::text[];
    IF btrim(coalesce(v_r.name, '')) = '' THEN v_falta := array_append(v_falta, 'nombre completo'::text); END IF;
    IF btrim(coalesce(v_r.phone, '')) = '' THEN v_falta := array_append(v_falta, 'telefono'::text); END IF;
    IF btrim(coalesce(v_r.address, '')) = '' THEN v_falta := array_append(v_falta, 'direccion'::text); END IF;
    IF btrim(coalesce(v_r.reference, '')) = '' THEN v_falta := array_append(v_falta, 'referencia de como llegar'::text); END IF;
    -- (owner 2026-10-04) A second contact phone is optional: kept when given, never asked for.
    IF v_r.amount IS NULL THEN v_falta := array_append(v_falta, 'monto en GYD (minimo 25,000)'::text); END IF;
    IF cardinality(v_falta) > 0 THEN
      v_msgs := v_msgs || ' FALTA: ' || array_to_string(v_falta, ', ') || ' de ' || v_label || '.';
    END IF;
    IF v_r.amount IS NOT NULL AND v_r.amount < 25000 THEN
      v_bajo := v_bajo || CASE WHEN v_bajo = '' THEN '' ELSE '; ' END
                || v_label || ' tiene ' || rtrim(trim(to_char(v_r.amount, 'FM999,999,990.99')), '.') || ' GYD';
    END IF;
  END LOOP;

  IF v_n = 0 THEN
    RETURN 'combo abierto, aun sin destinatarios. Pide del primer destinatario: nombre completo, telefono, direccion, '
           || 'referencia de como llegar y monto en GYD (minimo 25,000 por combo).' || v_aviso;
  END IF;
  IF v_bajo <> '' THEN
    v_msgs := v_msgs || ' el minimo por combo es 25,000 GYD (' || v_bajo || '): pregunta cuanto es para cada destinatario '
              || 'y que cada combo llegue a 25,000 GYD o mas.';
  END IF;
  IF crm_beneficiarios_completos(v_op.id) THEN
    RETURN 'Datos completos. Total a pagar: ' || rtrim(trim(to_char(v_total, 'FM999,999,990.99')), '.') || ' GYD (' || v_n
           || ' combo(s)). Pide el pago por MMG, todo por adelantado. Los productos se eligen DESPUES del pago, en una llamada '
           || 'con una persona del equipo: PROHIBIDO elegir o prometer productos concretos.' || v_aviso;
  END IF;
  RETURN 'combo con ' || v_n || ' destinatario(s), total ' || rtrim(trim(to_char(v_total, 'FM999,999,990.99')), '.') || ' GYD.'
         || v_msgs || ' Pideselo al cliente.' || v_aviso;
END $function$;
REVOKE ALL ON FUNCTION public.crm_registrar_destinatario_combo(uuid, text, text, text, text, text, numeric, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crm_registrar_destinatario_combo(uuid, text, text, text, text, text, numeric, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.crm_beneficiarios_completos(p_operation_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (198) A recharge: every current row is a 'recarga' with a valid Cuban mobile, and there are as many as
  -- recharges (cerebro_recarga_unidades; with no matching price, at least one).
  SELECT coalesce((SELECT CASE WHEN o.service_type = 'recarga' THEN
           (SELECT count(*) > 0
                   AND bool_and(b.beneficiary_type = 'recarga'
                                AND coalesce(cerebro_norm_celular_cu(b.phone), '') ~ '^[0-9]{8}$')
                   AND count(*) >= coalesce(cerebro_recarga_unidades(o.quoted_source_amount), 0)
              FROM remittance_beneficiaries b
             WHERE b.operation_id = o.id AND b.status = 'vigente')
         -- (208) A combo: at least one current recipient, and every one has name, phone, address, reference and an
         -- amount of at least 25,000 GYD (the minimum per combo). A second contact phone is optional (owner 2026-10-04).
         WHEN o.service_type = 'combo' THEN
           (SELECT count(*) > 0
                   AND bool_and(b.beneficiary_type = 'combo'
                                AND btrim(coalesce(b.name, '')) <> '' AND btrim(coalesce(b.phone, '')) <> ''
                                AND btrim(coalesce(b.address, '')) <> '' AND btrim(coalesce(b.reference, '')) <> ''
                                AND coalesce(b.amount, 0) >= 25000)
              FROM remittance_beneficiaries b
             WHERE b.operation_id = o.id AND b.status = 'vigente')
         ELSE (
    SELECT
      count(*) > 0
      AND bool_and(
        CASE
          WHEN beneficiary_type = 'zelle' THEN
            btrim(coalesce(name, '')) <> '' AND btrim(coalesce(zelle_account, '')) <> ''
          -- (188) A cash recipient has no card: phone, address and ID-card photo (150).
          WHEN beneficiary_type = 'efectivo_usd' THEN
            btrim(coalesce(phone, '')) <> '' AND btrim(coalesce(address, '')) <> ''
            AND btrim(coalesce(id_photo_wamid, '')) <> ''
          ELSE
            btrim(coalesce(card_number, '')) <> '' AND btrim(coalesce(phone, '')) <> ''
        END
      )
    FROM remittance_beneficiaries
    WHERE operation_id = p_operation_id
      AND status = 'vigente'
         ) END
    FROM remittance_operations o
   WHERE o.id = p_operation_id), false);
$function$;

-- (208) The return type grows by three columns, so the function is dropped and created again with the same ACL.
DROP FUNCTION public.crm_operaciones_de_conversacion(uuid);
CREATE OR REPLACE FUNCTION public.crm_operaciones_de_conversacion(p_conversation_id uuid)
 RETURNS TABLE(resolver_resultado text, resolver_operation_id uuid, resolver_candidatas integer, operation_id uuid, operation_status text, operation_service_type text, operation_source_currency text, operation_destination_currency text, operation_delivery_method text, operation_deposit_method text, operation_quoted_source_amount numeric, operation_quoted_destination_amount numeric, operation_admin_locked_fields jsonb, operation_created_at timestamp with time zone, operation_completed_at timestamp with time zone, beneficiary_id uuid, beneficiary_type text, beneficiary_name text, beneficiary_card_number text, beneficiary_phone text, beneficiary_zelle_account text, beneficiary_delivery_method text, beneficiary_amount numeric, beneficiary_currency text, beneficiary_position integer, operation_quoted_destination_rate numeric, operation_quoted_destination_origin text, beneficiary_amount_origin text, operation_is_history boolean, operation_beneficiaries_complete boolean, operation_delivery_mode text, operation_delivered_at timestamp with time zone, beneficiary_address text, beneficiary_id_photo_wamid text, beneficiary_id_photo_url text, beneficiary_reference text, beneficiary_contact_phone text, operation_combo_costo_gyd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id            uuid;
  v_resolver_resultado    text;
  v_resolver_operation_id uuid;
  v_resolver_candidatas   integer;
BEGIN
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  SELECT c.account_id INTO v_account_id
    FROM conversations c
   WHERE c.id = p_conversation_id;

  -- Same 42501 whether the conversation doesn't exist or belongs to an
  -- account the caller isn't a member of — see 097's file header for why.
  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  -- Inlined, NOT called by name — see 097's file header's "WHY THE
  -- RESOLVER LOGIC IS INLINED" section. Unchanged by this migration: the
  -- resolver only ever looks at live (non-terminal) operations, regardless
  -- of the history rows the RETURN QUERY below now also surfaces.
  SELECT count(*) INTO v_resolver_candidatas
    FROM remittance_operations
   WHERE conversation_id = p_conversation_id
     AND status NOT IN ('completed', 'cancelled');

  IF v_resolver_candidatas = 0 THEN
    v_resolver_resultado := 'ninguna';
    v_resolver_operation_id := NULL;
  ELSIF v_resolver_candidatas = 1 THEN
    v_resolver_resultado := 'unica';
    SELECT o.id INTO v_resolver_operation_id
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled');
  ELSE
    v_resolver_resultado := 'ambigua';
    v_resolver_operation_id := NULL;
  END IF;

  RETURN QUERY
  WITH ops AS (
    -- Current open (non-terminal) remesa operations — same set the RPC
    -- has always returned.
    SELECT o.*, false AS is_history
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled')
       AND o.service_type IN ('remesa', 'recarga', 'combo')  -- (200) recharges too, (208) combos
    UNION ALL
    -- The 10 most recently completed remesa operations of the same
    -- conversation — read-only history. A completed operation can never
    -- also match the branch above (status is exclusive), so UNION ALL
    -- cannot duplicate a row.
    SELECT h.*, true AS is_history
      FROM (
        SELECT o2.*
          FROM remittance_operations o2
         WHERE o2.conversation_id = p_conversation_id
           AND o2.status = 'completed'
           AND o2.service_type IN ('remesa', 'recarga', 'combo')  -- (200), (208)
         ORDER BY o2.completed_at DESC
         LIMIT 10
      ) h
  )
  SELECT
    r.resultado,
    r.operation_id,
    r.candidatas,
    o.id,
    o.status,
    o.service_type,
    o.source_currency,
    o.destination_currency,
    o.delivery_method,
    o.deposit_method,
    o.quoted_source_amount,
    o.quoted_destination_amount,
    o.admin_locked_fields,
    o.created_at,
    o.completed_at,
    b.id,
    b.beneficiary_type,
    b.name,
    b.card_number,
    b.phone,
    b.zelle_account,
    b.delivery_method,
    b.amount,
    b.currency,
    b.position,
    o.quoted_destination_rate,
    o.quoted_destination_origin,
    b.amount_origin,
    o.is_history,
    CASE WHEN o.id IS NULL THEN NULL ELSE crm_beneficiarios_completos(o.id) END,
    o.delivery_mode,
    CASE WHEN o.is_history THEN o.completed_at ELSE NULL END,
    -- (189) a cash recipient (150): address and the ID-card photo, with the URL of the message it came in.
    b.address,
    b.id_photo_wamid,
    (SELECT m.media_url FROM messages m
      WHERE b.id_photo_wamid IS NOT NULL AND m.message_id = b.id_photo_wamid
        AND m.conversation_id = o.conversation_id
      ORDER BY m.created_at DESC LIMIT 1),
    -- (208) A combo recipient: how to get there and the second contact phone; the combo's cost (set by the admin).
    b.reference,
    b.contact_phone,
    o.combo_costo_gyd
  -- A single synthetic one-row source (no FROM) rather than a set-returning
  -- call, so the resolver values still surface even when zero operations
  -- match below (the 'ninguna' case) — LEFT JOIN against zero rows on the
  -- left would otherwise return zero rows overall, not one resolver-only row.
  FROM (SELECT v_resolver_resultado AS resultado, v_resolver_operation_id AS operation_id, v_resolver_candidatas AS candidatas) r
  LEFT JOIN ops o ON true
  LEFT JOIN remittance_beneficiaries b
         ON b.operation_id = o.id
        AND b.status = 'vigente'
  ORDER BY o.is_history ASC NULLS LAST, o.created_at DESC NULLS LAST, o.completed_at DESC NULLS LAST, b.position ASC NULLS LAST;
END $function$;
REVOKE ALL ON FUNCTION public.crm_operaciones_de_conversacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_operaciones_de_conversacion(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.crm_agregar_beneficiario(p_operation_id uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id        uuid;
  v_op_status          text;
  v_service_type       text;
  v_key                text;
  v_new_id             uuid;
  v_next_position      integer;
  v_next_block_index   integer;

  v_beneficiary_type   text;
  v_name               text;
  v_card_number        text;
  v_phone              text;
  v_zelle_account      text;
  v_delivery_method    text;
  v_amount             numeric;
  v_currency           text;
  v_address            text;
  v_reference          text;
  v_contact            text;
BEGIN
  SELECT account_id, status, service_type
    INTO v_account_id, v_op_status, v_service_type
    FROM remittance_operations
   WHERE id = p_operation_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to add a beneficiary to this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF v_service_type IS NULL OR v_service_type NOT IN ('remesa', 'recarga', 'combo') THEN
    RAISE EXCEPTION 'beneficiaries can only be added to remesa, recarga or combo operations' USING ERRCODE = '22023';
  END IF;

  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION 'datos must be a JSON object' USING ERRCODE = '22023';
  END IF;

  -- Reject unknown keys up front, same posture as crm_corregir_beneficiario.
  FOR v_key IN SELECT jsonb_object_keys(p_datos) LOOP
    IF v_key NOT IN ('beneficiary_type', 'name', 'card_number', 'phone', 'zelle_account',
                      'delivery_method', 'amount', 'currency', 'address', 'reference', 'contact_phone') THEN
      RAISE EXCEPTION 'unknown field: %', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_beneficiary_type := p_datos ->> 'beneficiary_type';
  IF v_beneficiary_type IS NULL
     OR v_beneficiary_type NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution', 'recarga', 'combo') THEN
    RAISE EXCEPTION 'invalid beneficiary_type: %', v_beneficiary_type USING ERRCODE = '22023';
  END IF;

  -- (208) A combo takes combo recipients only, and only a combo does. Address, reference and contact_phone belong to
  -- a combo recipient alone.
  IF (v_service_type = 'combo') <> (v_beneficiary_type = 'combo') THEN
    RAISE EXCEPTION 'a combo takes combo recipients only, and no other operation does' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type <> 'combo' AND (p_datos ? 'address' OR p_datos ? 'reference' OR p_datos ? 'contact_phone') THEN
    RAISE EXCEPTION 'unknown field: address, reference and contact_phone are for combo recipients' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type = 'combo' THEN
    v_name := nullif(btrim(coalesce(p_datos ->> 'name', '')), '');
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'name is required for a combo recipient' USING ERRCODE = '22023';
    END IF;
    v_phone := regexp_replace(coalesce(p_datos ->> 'phone', ''), '[^0-9]', '', 'g');
    IF length(v_phone) = 10 AND left(v_phone, 2) = '53' THEN v_phone := substr(v_phone, 3); END IF;
    IF v_phone !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_contact := nullif(regexp_replace(coalesce(p_datos ->> 'contact_phone', ''), '[^0-9]', '', 'g'), '');
    IF v_contact IS NOT NULL AND length(v_contact) = 10 AND left(v_contact, 2) = '53' THEN v_contact := substr(v_contact, 3); END IF;
    IF v_contact IS NOT NULL AND v_contact !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'contact_phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_address := nullif(btrim(coalesce(p_datos ->> 'address', '')), '');
    v_reference := nullif(btrim(coalesce(p_datos ->> 'reference', '')), '');
    IF NOT (p_datos ? 'amount') OR p_datos ->> 'amount' IS NULL OR (p_datos ->> 'amount')::numeric <= 0 THEN
      RAISE EXCEPTION 'amount is required and must be greater than 0' USING ERRCODE = '22023';
    END IF;
    v_amount := (p_datos ->> 'amount')::numeric;
    IF coalesce(p_datos ->> 'currency', 'GYD') <> 'GYD' THEN
      RAISE EXCEPTION 'a combo amount is in GYD' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(max(position), 0) + 1 INTO v_next_position
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, address, reference, contact_phone,
                                          amount, currency, position, status, source, block_index)
    VALUES (p_operation_id, 'combo', v_name, v_phone, v_address, v_reference, v_contact,
            v_amount, 'GYD', v_next_position, 'vigente', 'admin_addition', v_next_block_index)
    RETURNING id INTO v_new_id;
    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields ||
           jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now())),
           quoted_source_amount = (SELECT coalesce(sum(b.amount), 0) FROM remittance_beneficiaries b
                                    WHERE b.operation_id = p_operation_id AND b.status = 'vigente' AND b.beneficiary_type = 'combo')
     WHERE id = p_operation_id;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,name,phone,address,reference,contact_phone,amount,currency',
            'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);
    RETURN jsonb_build_object('id', v_new_id, 'complete', crm_beneficiarios_completos(p_operation_id));
  END IF;

  -- (200) A recharge takes recharge numbers only (one Cuban mobile per recharge), and a remesa none: no card, no
  -- amount. Same lock and audit as below.
  IF (v_service_type = 'recarga') <> (v_beneficiary_type = 'recarga') THEN
    RAISE EXCEPTION 'a recharge takes recharge numbers only, and a remesa none' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type = 'recarga' THEN
    v_phone := cerebro_norm_celular_cu(p_datos ->> 'phone');
    IF coalesce(v_phone, '') !~ '^[0-9]{8}$' THEN
      RAISE EXCEPTION 'phone must be a Cuban mobile number' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(max(position), 0) + 1 INTO v_next_position
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, status, source, block_index)
    VALUES (p_operation_id, 'recarga', v_phone, v_next_position, 'vigente', 'admin_addition', v_next_block_index)
    RETURNING id INTO v_new_id;
    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields ||
           jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
     WHERE id = p_operation_id;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,phone',
            'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);
    RETURN jsonb_build_object('id', v_new_id, 'complete', crm_beneficiarios_completos(p_operation_id));
  END IF;

  -- amount and currency are required: unlike a correction, a newly added
  -- beneficiary has no prior row to fall back on for its destination amount.
  IF NOT (p_datos ? 'amount') OR p_datos ->> 'amount' IS NULL
     OR (p_datos ->> 'amount')::numeric <= 0 THEN
    RAISE EXCEPTION 'amount is required and must be greater than 0' USING ERRCODE = '22023';
  END IF;
  v_amount := (p_datos ->> 'amount')::numeric;

  IF NOT (p_datos ? 'currency') OR p_datos ->> 'currency' IS NULL
     OR p_datos ->> 'currency' !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'currency is required and must be a 3-letter uppercase code' USING ERRCODE = '22023';
  END IF;
  v_currency := p_datos ->> 'currency';

  v_delivery_method := p_datos ->> 'delivery_method';
  IF p_datos ? 'delivery_method' AND btrim(coalesce(v_delivery_method, '')) = '' THEN
    RAISE EXCEPTION 'delivery_method must not be empty' USING ERRCODE = '22023';
  END IF;

  IF v_beneficiary_type = 'zelle' THEN
    v_name := p_datos ->> 'name';
    v_zelle_account := p_datos ->> 'zelle_account';
    IF btrim(coalesce(v_name, '')) = '' THEN
      RAISE EXCEPTION 'name is required for a zelle beneficiary' USING ERRCODE = '22023';
    END IF;
    IF btrim(coalesce(v_zelle_account, '')) = '' THEN
      RAISE EXCEPTION 'zelle_account is required for a zelle beneficiary' USING ERRCODE = '22023';
    END IF;
    v_card_number := NULL;
    v_phone := NULL;
  ELSE
    v_card_number := p_datos ->> 'card_number';
    v_phone := p_datos ->> 'phone';
    IF v_card_number IS NULL OR v_card_number !~ '^[0-9]{16}$' THEN
      RAISE EXCEPTION 'card_number must be exactly 16 digits' USING ERRCODE = '22023';
    END IF;
    -- (190) The phone is optional: the owner records a card the customer gave without its phone, and closes the
    -- remesa manually (crm_cerrar_operacion_manual). A given phone is still validated; the remesa stays incomplete
    -- (crm_beneficiarios_completos) so a normal delivery still needs it.
    v_phone := nullif(btrim(coalesce(v_phone, '')), '');
    IF v_phone IS NOT NULL AND v_phone !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_name := p_datos ->> 'name';
    v_zelle_account := NULL;
  END IF;

  SELECT coalesce(max(position), 0) + 1 INTO v_next_position
    FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';

  SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
    FROM remittance_beneficiaries WHERE operation_id = p_operation_id;

  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone, zelle_account,
    delivery_method, amount, currency, position, status, source, block_index
  ) VALUES (
    p_operation_id, v_beneficiary_type, v_name, v_card_number, v_phone, v_zelle_account,
    v_delivery_method, v_amount, v_currency, v_next_position, 'vigente', 'admin_addition', v_next_block_index
  ) RETURNING id INTO v_new_id;

  -- Lock beneficiaries on this operation so automation cannot overwrite or
  -- delete the row a human just added — same lock crm_corregir_beneficiario
  -- and crm_reasignar_beneficiario place (098), honored by
  -- cerebro_sync_beneficiarios' early return (also 098).
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields ||
         jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,name,card_number,phone,zelle_account,delivery_method,amount,currency',
          'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);

  RETURN jsonb_build_object(
    'id', v_new_id,
    'complete', crm_beneficiarios_completos(p_operation_id)
  );
END $function$;

CREATE OR REPLACE FUNCTION public.crm_cerrar_operacion_manual(p_operation_id uuid, p_motivo text DEFAULT NULL::text, p_notify boolean DEFAULT false, p_delivery_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_status_before text;
  v_completed_at  timestamptz;
  v_motivo        text := coalesce(nullif(btrim(p_motivo), ''), 'Closed manually from the panel');
BEGIN
  SELECT account_id, status INTO v_account_id, v_status_before
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can close an operation manually' USING ERRCODE = '42501';
  END IF;
  -- (191) No typed reason any more: the fixed note above is audited unless one is given.
  IF length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'the reason must be at most 500 characters' USING ERRCODE = '22023';
  END IF;
  -- (196) The service chosen in the panel when the remesa has no beneficiary, so the calculator can price it.
  IF p_delivery_method IS NOT NULL THEN
    IF p_delivery_method NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo') THEN
      RAISE EXCEPTION 'unknown service: %', p_delivery_method USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente') THEN
      RAISE EXCEPTION 'this remesa already has a beneficiary: its service comes from it' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_status_before NOT IN ('ready_to_transfer', 'transferring') THEN
    RAISE EXCEPTION 'only a verified operation can be closed manually (status %)', v_status_before USING ERRCODE = '22023';
  END IF;

  -- One statement, like crm_entregar_operacion: completed_at (040) and the calculator feed read this row image.
  UPDATE remittance_operations
     SET status = 'completed', delivery_mode = 'closed_manually', delivered_by = auth.uid(),
         -- (196) In the same UPDATE, so the calculator feed (AFTER UPDATE OF status) sees the service.
         -- (200) 'recarga' is a kind of operation, not a delivery method: it sets service_type. (208) So is 'combo'.
         delivery_method = CASE WHEN p_delivery_method IN ('recarga', 'combo') THEN delivery_method ELSE coalesce(p_delivery_method, delivery_method) END,
         service_type = CASE WHEN p_delivery_method IN ('recarga', 'combo') THEN p_delivery_method ELSE service_type END,
         -- (191) Silent by default (p_notify false); the bell on the panel can turn the notice on.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'completed' END
   WHERE id = p_operation_id
  RETURNING completed_at INTO v_completed_at;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_manual_close', wacrm_current_actor(),
          v_motivo, jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', 'completed', 'delivery_mode', 'closed_manually', 'notify', p_notify)
            || CASE WHEN p_delivery_method IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('delivery_method', p_delivery_method) END);

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;

CREATE OR REPLACE FUNCTION public.crm_set_combo_costo(p_operation_id uuid, p_costo_gyd numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- (208) The admin enters what a combo cost (GYD); NULL clears it. Same role as closing an operation by hand.
DECLARE
  v_account_id uuid;
  v_service    text;
  v_before     numeric;
BEGIN
  SELECT account_id, service_type, combo_costo_gyd INTO v_account_id, v_service, v_before
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can set the cost of a combo' USING ERRCODE = '42501';
  END IF;
  IF v_service IS DISTINCT FROM 'combo' THEN
    RAISE EXCEPTION 'only a combo has a cost entered by hand' USING ERRCODE = '22023';
  END IF;
  IF p_costo_gyd IS NOT NULL AND (p_costo_gyd < 0 OR p_costo_gyd >= 1e9) THEN
    RAISE EXCEPTION 'the cost must be between 0 and 1e9' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_operations SET combo_costo_gyd = p_costo_gyd WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'combo_costo_gyd', 'human_combo_cost_set', wacrm_current_actor(),
          jsonb_build_object('combo_costo_gyd', v_before), jsonb_build_object('combo_costo_gyd', p_costo_gyd));

  RETURN jsonb_build_object('combo_costo_gyd', p_costo_gyd);
END $function$;
REVOKE ALL ON FUNCTION public.crm_set_combo_costo(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_set_combo_costo(uuid, numeric) TO authenticated, service_role;

-- The bot now collects the combo's data and the payment; the products are still chosen by a person after paying.
UPDATE public.cerebro_servicios
   SET hechos = $combo208$Envio de combos de comida y productos a Cuba. NO es un catalogo cerrado con precios: el combo se arma a medida segun lo que haya en existencia, y hay productos que se agotan. El enlace de muestra sirve para hacerse una idea de lo que lleva un combo, no es una lista de precios. El minimo son 25,000 GYD por combo: se van sumando productos hasta llegar a ese monto, y se puede pedir por mas. El precio INCLUYE el envio hasta la casa. Llega a toda Cuba y cuesta lo mismo para cualquier provincia. Plazos de entrega: Habana, Artemisa y Mayabeque de 3 a 5 dias; Pinar del Rio y Matanzas de 5 a 7; Cienfuegos y Villa Clara de 7 a 10; el resto de provincias de 10 a 15 dias. Se paga por adelantado por MMG, igual que una remesa. Los productos concretos se eligen DESPUES de pagar, en una llamada con una persona del equipo: el asistente no arma el combo ni elige productos. Por cada combo el asistente recoge, del destinatario: nombre completo, telefono, direccion lo mas completa posible, una referencia de como llegar o como es el lugar, y el monto de ESE combo (minimo 25,000 GYD cada uno; con varios combos, pregunta cuanto es para cada destinatario y comprueba que cada uno llegue al minimo). Los datos pueden llegar en varios mensajes. El asistente SI gestiona el pedido: suma los combos para dar el total y el cliente paga todo por adelantado por MMG, como una remesa; despues una persona del equipo lo llama para elegir los productos. PROHIBIDO elegir o prometer productos concretos. PROHIBIDO ofrecer rebajas, descuentos o precios especiales. Si el cliente pide rebaja, di la tarifa fija y que cualquier rebaja la trata una persona del equipo.$combo208$,
       notas_internas = $combo208$Osmany 8-ago: minimo 25,000 GYD, a medida por disponibilidad, envio incluido, mismo precio toda Cuba. 208 (4-oct): el asistente recoge los destinatarios del combo (nombre, telefono, direccion, referencia, monto; un telefono de contacto extra solo si el cliente lo da); los productos los elige una persona en una llamada posterior.$combo208$,
       requiere_humano = false,
       actualizado = now()
 WHERE clave = 'combos';
