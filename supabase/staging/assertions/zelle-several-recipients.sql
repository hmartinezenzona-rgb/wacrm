\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 274 (cerebro_guardar_zelle: several Zelle recipients on one operation). Self-reverting:
-- BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA zelle N', phones 5990274xxxx, fake accounts @example.com.
-- odd/notes/db-tools-progress.md (274, gap 1 of the S5b measurement, case C).
-- Cases (number = label in the failure message):
--   1  legacy 4-argument call (the tool today) and the 6-argument call of cerebro_guardar_zelle_auto still work;
--      one recipient, the same account corrected = the row is replaced (one vigente row), "sin cambios" when equal
--   2  p_agregar => a second recipient is ADDED (positions 1, 2), names stored exactly as passed, the first stays vigente
--   3  the same account again (no parameter, N = 2) corrects THAT recipient only (replaces it, the other is untouched)
--   4  p_posicion = 2 corrects the second recipient (name only), the first is untouched; p_posicion = 1 with a new account
--      replaces slot 1 and the holder goes with the account
--   5  N = 2 and a new account with no parameter: nothing is written and the answer names agregar / posicion
--   6  p_posicion beyond N + 1 is refused; p_posicion = N + 1 appends
--   7  per-recipient amount (USD): kept on its own row, preserved by a later call without amount, changed by a new one
--   8  250 several-operations targeting: with p_op the recipients of ANOTHER open operation are never touched
--   9  one recipient + a different account: (285) refused, nothing written; posicion=1 corrects it
--  10  the parser keeps a name with a pipe or an accent untouched; the answer lists every recipient
--  11  ACL: service_role only (authenticated and anon cannot execute)
-- =====================================================================

CREATE FUNCTION pg_temp.z_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990274' || lpad(p_n::text, 4, '0'), 'PRUEBA zelle ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.z_op(p_c record, p_rail text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, 'collecting_information', 'remesa', p_rail, 'GYD', 0, clock_timestamp())
  RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.z_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

-- vigente Zelle recipients of an operation as "pos:name:account[:amount]" ordered by position
CREATE FUNCTION pg_temp.z_vig(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(position || ':' || coalesce(name, '-') || ':' || coalesce(zelle_account, '-')
                             || CASE WHEN amount IS NOT NULL THEN ':' || trim_scale(amount)::text || coalesce(currency, '') ELSE '' END,
                             ',' ORDER BY position), 'none')
    FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente' AND beneficiary_type = 'zelle';
$f$;

CREATE FUNCTION pg_temp.z_acc(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = p_op AND beneficiary_type = 'zelle';
$f$;

DO $$
DECLARE
  c record; c2 record; v_op uuid; v_op2 uuid; v_a text;
BEGIN
  -- 1 legacy shapes
  SELECT * INTO c FROM pg_temp.z_conv(1);
  v_op := pg_temp.z_op(c, 'zelle');
  SELECT accion INTO v_a FROM cerebro_guardar_zelle(c.conv, 'Maria Lopez', 'maria@example.com', 'ex1');
  PERFORM pg_temp.z_eq('1 first save', pg_temp.z_vig(v_op), '1:Maria Lopez:maria@example.com');
  PERFORM pg_temp.z_eq('1 complete text', (v_a LIKE '%Completo.%')::text, 'true');
  SELECT accion INTO v_a FROM cerebro_guardar_zelle(c.conv, 'Maria Lopez', 'maria@example.com', 'ex1');
  PERFORM pg_temp.z_eq('1 sin cambios', (v_a LIKE 'sin cambios%')::text, 'true');
  PERFORM cerebro_guardar_zelle(c.conv, 'Maria J Lopez', 'maria@example.com', 'ex2');
  PERFORM pg_temp.z_eq('1 same account corrected (replace)', pg_temp.z_vig(v_op), '1:Maria J Lopez:maria@example.com');
  PERFORM pg_temp.z_eq('1 old generation retired', (SELECT count(*)::text FROM remittance_beneficiaries
                         WHERE operation_id = v_op AND beneficiary_type = 'zelle' AND status = 'reemplazado'), '1');
  PERFORM cerebro_guardar_zelle(c.conv, 'Maria J Lopez', 'maria@example.com', 'ex3', v_op, 'Registrar zelle auto');
  PERFORM pg_temp.z_eq('1 six-argument call (zelle_auto shape)', pg_temp.z_vig(v_op), '1:Maria J Lopez:maria@example.com');

  -- 2 add another recipient
  SELECT accion INTO v_a FROM cerebro_guardar_zelle(c.conv, 'Juan Perez', '5551234567', 'ex4', NULL, 'registrar_beneficiario_zelle', NULL, true);
  PERFORM pg_temp.z_eq('2 second recipient added', pg_temp.z_vig(v_op), '1:Maria J Lopez:maria@example.com,2:Juan Perez:5551234567');
  PERFORM pg_temp.z_eq('2 answer says 2 de 2', (v_a LIKE '%destinatario 2 de 2%')::text, 'true');
  PERFORM pg_temp.z_eq('2 answer lists both', (v_a LIKE '%Maria J Lopez%' AND v_a LIKE '%Juan Perez%')::text, 'true');

  -- 3 same account again, no parameter: corrects THAT recipient only
  PERFORM cerebro_guardar_zelle(c.conv, 'Juan A Perez', '5551234567', 'ex5');
  PERFORM pg_temp.z_eq('3 same account corrects the second only', pg_temp.z_vig(v_op), '1:Maria J Lopez:maria@example.com,2:Juan A Perez:5551234567');
  SELECT accion INTO v_a FROM cerebro_guardar_zelle(c.conv, 'Juan A Perez', '5551234567', 'ex5b');
  PERFORM pg_temp.z_eq('3 sin cambios with two recipients', (v_a LIKE 'sin cambios%')::text, 'true');

  -- 4 slot correction
  PERFORM cerebro_guardar_zelle(c.conv, 'Juan Alberto Perez', NULL, 'ex6', NULL, 'registrar_beneficiario_zelle', 2);
  PERFORM pg_temp.z_eq('4 slot 2 name only', pg_temp.z_vig(v_op), '1:Maria J Lopez:maria@example.com,2:Juan Alberto Perez:5551234567');
  PERFORM cerebro_guardar_zelle(c.conv, 'Ana Gomez', 'ana@example.com', 'ex7', NULL, 'registrar_beneficiario_zelle', 1);
  PERFORM pg_temp.z_eq('4 slot 1 new account replaces slot 1', pg_temp.z_vig(v_op), '1:Ana Gomez:ana@example.com,2:Juan Alberto Perez:5551234567');
  PERFORM cerebro_guardar_zelle(c.conv, NULL, 'ana2@example.com', 'ex7b', NULL, 'registrar_beneficiario_zelle', 1);
  PERFORM pg_temp.z_eq('4 slot 1 new account without name starts without holder', pg_temp.z_vig(v_op), '1:-:ana2@example.com,2:Juan Alberto Perez:5551234567');
  PERFORM cerebro_guardar_zelle(c.conv, 'Ana Gomez', NULL, 'ex7c', NULL, 'registrar_beneficiario_zelle', 1);
  PERFORM pg_temp.z_eq('4 slot 1 holder back', pg_temp.z_vig(v_op), '1:Ana Gomez:ana2@example.com,2:Juan Alberto Perez:5551234567');

  -- 5 N = 2, a new complete payee with no parameter: refuse, write nothing
  SELECT accion INTO v_a FROM cerebro_guardar_zelle(c.conv, 'Pedro Ruiz', 'pedro@example.com', 'ex8');
  PERFORM pg_temp.z_eq('5 nothing written', pg_temp.z_vig(v_op), '1:Ana Gomez:ana2@example.com,2:Juan Alberto Perez:5551234567');
  PERFORM pg_temp.z_eq('5 answer names the options', (v_a LIKE 'NO SE GUARDO NADA%' AND v_a LIKE '%agregar%' AND v_a LIKE '%posicion%')::text, 'true');

  -- 6 positions
  SELECT accion INTO v_a FROM cerebro_guardar_zelle(c.conv, 'Pedro Ruiz', 'pedro@example.com', 'ex9', NULL, 'registrar_beneficiario_zelle', 5);
  PERFORM pg_temp.z_eq('6 invalid position writes nothing', pg_temp.z_vig(v_op), '1:Ana Gomez:ana2@example.com,2:Juan Alberto Perez:5551234567');
  PERFORM pg_temp.z_eq('6 invalid position text', (v_a LIKE 'NO SE GUARDO NADA%')::text, 'true');
  PERFORM cerebro_guardar_zelle(c.conv, 'Pedro Ruiz', 'pedro@example.com', 'ex10', NULL, 'registrar_beneficiario_zelle', 3);
  PERFORM pg_temp.z_eq('6 position N+1 appends', pg_temp.z_vig(v_op),
    '1:Ana Gomez:ana2@example.com,2:Juan Alberto Perez:5551234567,3:Pedro Ruiz:pedro@example.com');

  -- 7 per-recipient amount
  SELECT * INTO c2 FROM pg_temp.z_conv(2);
  v_op2 := pg_temp.z_op(c2, 'zelle');
  PERFORM cerebro_guardar_zelle(c2.conv, 'Rosa Diaz', 'rosa@example.com', 'ex11', NULL, 'registrar_beneficiario_zelle', NULL, false, 60);
  PERFORM cerebro_guardar_zelle(c2.conv, 'Luis Mora', 'luis@example.com', 'ex12', NULL, 'registrar_beneficiario_zelle', NULL, true, 40);
  PERFORM pg_temp.z_eq('7 amounts per recipient', pg_temp.z_vig(v_op2), '1:Rosa Diaz:rosa@example.com:60USD,2:Luis Mora:luis@example.com:40USD');
  PERFORM cerebro_guardar_zelle(c2.conv, 'Rosa M Diaz', 'rosa@example.com', 'ex13');
  PERFORM pg_temp.z_eq('7 amount kept when the call has none', pg_temp.z_vig(v_op2), '1:Rosa M Diaz:rosa@example.com:60USD,2:Luis Mora:luis@example.com:40USD');
  PERFORM cerebro_guardar_zelle(c2.conv, NULL, NULL, 'ex14', NULL, 'registrar_beneficiario_zelle', 2, false, 45.5);
  PERFORM pg_temp.z_eq('7 amount changed', pg_temp.z_vig(v_op2), '1:Rosa M Diaz:rosa@example.com:60USD,2:Luis Mora:luis@example.com:45.5USD');

  -- 8 several operations: p_op targets exactly one
  SELECT * INTO c2 FROM pg_temp.z_conv(3);
  v_op := pg_temp.z_op(c2, 'zelle');
  PERFORM cerebro_guardar_zelle(c2.conv, 'Eva Sol', 'eva@example.com', 'ex15', v_op, 'Registrar zelle auto');
  v_op2 := pg_temp.z_op(c2, 'zelle');
  PERFORM cerebro_guardar_zelle(c2.conv, 'Omar Sol', 'omar@example.com', 'ex16', v_op2, 'registrar_beneficiario_zelle', NULL, true);
  PERFORM pg_temp.z_eq('8 first operation untouched', pg_temp.z_vig(v_op), '1:Eva Sol:eva@example.com');
  PERFORM pg_temp.z_eq('8 second operation has its own recipient', pg_temp.z_vig(v_op2), '1:Omar Sol:omar@example.com');
  PERFORM cerebro_guardar_zelle(c2.conv, 'Ivo Sol', 'ivo@example.com', 'ex17', v_op2, 'registrar_beneficiario_zelle', NULL, true);
  PERFORM pg_temp.z_eq('8 add on the second operation', pg_temp.z_vig(v_op2), '1:Omar Sol:omar@example.com,2:Ivo Sol:ivo@example.com');
  PERFORM pg_temp.z_eq('8 first operation still untouched', pg_temp.z_vig(v_op), '1:Eva Sol:eva@example.com');

  -- 9 one recipient, a different account: (285) refused, nothing written, the answer asks other person (agregar) or correction (posicion)
  SELECT * INTO c2 FROM pg_temp.z_conv(4);
  v_op := pg_temp.z_op(c2, 'zelle');
  PERFORM cerebro_guardar_zelle(c2.conv, 'Nora Paz', 'nora@example.com', 'ex18');
  SELECT accion INTO v_a FROM cerebro_guardar_zelle(c2.conv, 'Nora Paz', 'nora2@example.com', 'ex19');
  PERFORM pg_temp.z_eq('9 refused, first intact', pg_temp.z_vig(v_op), '1:Nora Paz:nora@example.com');
  PERFORM pg_temp.z_eq('9 hint to add or correct', (v_a LIKE 'NO SE GUARDO NADA:%agregar=true%posicion=1%')::text, 'true');
  PERFORM cerebro_guardar_zelle(c2.conv, 'Nora Paz', 'nora2@example.com', 'ex19b', NULL, 'registrar_beneficiario_zelle', 1);
  PERFORM pg_temp.z_eq('9 position corrects it', pg_temp.z_vig(v_op), '1:Nora Paz:nora2@example.com');

  -- 10 name with a pipe and an accent, exactly as passed
  SELECT * INTO c2 FROM pg_temp.z_conv(5);
  v_op := pg_temp.z_op(c2, 'zelle');
  PERFORM cerebro_guardar_zelle(c2.conv, 'José | Ángel Núñez', 'jose@example.com', 'ex20');
  PERFORM cerebro_guardar_zelle(c2.conv, 'Marta  Ríos', 'marta@example.com', 'ex21', NULL, 'registrar_beneficiario_zelle', NULL, true, 10);
  PERFORM pg_temp.z_eq('10 names exactly as passed', pg_temp.z_vig(v_op), '1:José | Ángel Núñez:jose@example.com,2:Marta  Ríos:marta@example.com:10USD');

  -- 11 ACL
  PERFORM pg_temp.z_eq('11 service_role only',
    has_function_privilege('authenticated', 'cerebro_guardar_zelle(uuid,text,text,text,uuid,text,integer,boolean,numeric)', 'EXECUTE')::text || ':' ||
    has_function_privilege('anon', 'cerebro_guardar_zelle(uuid,text,text,text,uuid,text,integer,boolean,numeric)', 'EXECUTE')::text || ':' ||
    has_function_privilege('service_role', 'cerebro_guardar_zelle(uuid,text,text,text,uuid,text,integer,boolean,numeric)', 'EXECUTE')::text, 'false:false:true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
