-- 324: a line deleted on purpose covers its operation (226); a void without
-- deleted_at still counts as a discrepancy. Fixture rolled back on purpose.
DO $$
DECLARE
  v_acc uuid; v_user uuid; v_contact uuid; v_conv uuid;
  v_op_borrada uuid; v_op_anulada uuid;
  v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
  v jsonb; v_lista jsonb; v_fail text := '';
BEGIN
  SELECT p.account_id, p.user_id INTO v_acc, v_user
    FROM profiles p JOIN auth.users au ON au.id = p.user_id
   WHERE p.account_id IS NOT NULL LIMIT 1;
  IF v_acc IS NULL THEN RAISE EXCEPTION '324: no hay cuenta valida'; END IF;

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '59902993240', 'PRUEBA 324') RETURNING id INTO v_contact;

  INSERT INTO conversations (user_id, account_id, contact_id, status)
  VALUES (v_user, v_acc, v_contact, 'open') RETURNING id INTO v_conv;

  -- Un guardia de automatizacion marcaba en incidencia cualquier operacion
  -- insertada ya como completada; se crea abierta y se completa como lo haria
  -- un administrador.
  PERFORM set_config('wacrm.origin', 'admin', true);

  -- Operación completada cuya línea se borró a propósito (deleted_at).
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status,
                                     quoted_source_amount, service_type,
                                     source_currency, destination_currency)
  VALUES (v_acc, v_conv, v_contact, 'awaiting_deposit', 1000, 'remesa', 'USD', 'CUP')
  RETURNING id INTO v_op_borrada;
  UPDATE remittance_operations SET status = 'completed', completed_at = now()
   WHERE id = v_op_borrada;

  INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, service,
                                             amount, amount_currency, operation_id,
                                             completed_at, voided_at, deleted_at)
  VALUES (v_acc, 'completed_operation', 'void', v_hoy, 'CUP', 1000, 'CUP', v_op_borrada,
          now(), now(), now());

  -- Operación completada cuya línea se anuló sin borrarla: sigue siendo hueco.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status,
                                     quoted_source_amount, service_type,
                                     source_currency, destination_currency)
  VALUES (v_acc, v_conv, v_contact, 'awaiting_deposit', 2000, 'remesa', 'USD', 'CUP')
  RETURNING id INTO v_op_anulada;
  UPDATE remittance_operations SET status = 'completed', completed_at = now()
   WHERE id = v_op_anulada;

  INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, service,
                                             amount, amount_currency, operation_id,
                                             completed_at, voided_at)
  VALUES (v_acc, 'completed_operation', 'void', v_hoy, 'CUP', 2000, 'CUP', v_op_anulada,
          now(), now());

  v := hermes_cuadre_finanzas(v_hoy, v_hoy);
  v_lista := coalesce(v->'crm'->'sin_linea_en_finanzas', '[]'::jsonb);

  IF v_lista @> jsonb_build_array(jsonb_build_object('operacion', left(v_op_borrada::text, 8))) THEN
    v_fail := v_fail || ' 1:borrada-sigue-marcada';
  END IF;
  IF NOT (v_lista @> jsonb_build_array(jsonb_build_object('operacion', left(v_op_anulada::text, 8)))) THEN
    v_fail := v_fail || ' 2:anulada-no-marcada';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION '324 FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
