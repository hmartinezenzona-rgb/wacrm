-- 323: the alert refreshes instead of piling up, and a read one is replaced by
-- a fresh alert. Fixture rolled back on purpose.
DO $$
DECLARE
  v_acc uuid; v_user uuid; v_contact uuid; v_conv uuid;
  v_n1 int; v_n2 int; v_rows int; v_rows2 int;
  v_first timestamptz; v_second timestamptz; v_leidas int;
  v_fail text := '';
BEGIN
  SELECT p.account_id, p.user_id INTO v_acc, v_user
    FROM profiles p JOIN auth.users au ON au.id = p.user_id
   WHERE p.account_id IS NOT NULL LIMIT 1;
  IF v_acc IS NULL THEN RAISE EXCEPTION '323: no hay cuenta con perfil valido'; END IF;

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '59902993230', 'PRUEBA 323') RETURNING id INTO v_contact;

  INSERT INTO conversations (user_id, account_id, contact_id, status)
  VALUES (v_user, v_acc, v_contact, 'open') RETURNING id INTO v_conv;

  v_n1 := cerebro_avisar_atascado_fila(v_acc, v_conv, v_contact, 'PRUEBA 323 esperando', 'cuerpo uno');
  SELECT count(*), max(created_at) INTO v_rows, v_first
    FROM notifications WHERE type = 'chat_atascado' AND conversation_id = v_conv;

  IF v_rows = 0 THEN v_fail := v_fail || ' 1:sin-aviso'; END IF;
  IF v_rows <> v_n1 THEN v_fail := v_fail || ' 2:cuenta'; END IF;

  -- Second pass: same chat still stuck. It must refresh, not duplicate.
  PERFORM pg_sleep(0.02);
  v_n2 := cerebro_avisar_atascado_fila(v_acc, v_conv, v_contact, 'PRUEBA 323 esperando', 'cuerpo dos');
  SELECT count(*), max(created_at) INTO v_rows2, v_second
    FROM notifications WHERE type = 'chat_atascado' AND conversation_id = v_conv;

  IF v_rows2 <> v_rows THEN v_fail := v_fail || ' 3:duplico'; END IF;
  IF v_n2 <> v_n1 THEN v_fail := v_fail || ' 4:cuenta-refresco'; END IF;
  IF v_second <= v_first THEN v_fail := v_fail || ' 5:no-refresco'; END IF;

  -- Read it, then a third pass: a read alert is replaced by a fresh one.
  UPDATE notifications SET read_at = now()
   WHERE type = 'chat_atascado' AND conversation_id = v_conv;
  PERFORM cerebro_avisar_atascado_fila(v_acc, v_conv, v_contact, 'PRUEBA 323 esperando', 'cuerpo tres');
  SELECT count(*) FILTER (WHERE read_at IS NULL) INTO v_leidas
    FROM notifications WHERE type = 'chat_atascado' AND conversation_id = v_conv;
  IF v_leidas <> v_n1 THEN v_fail := v_fail || ' 6:no-reaviso'; END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION '323 FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
