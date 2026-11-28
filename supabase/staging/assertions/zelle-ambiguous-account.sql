\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 285 (registrar_beneficiario_zelle refuses a different account when it is ambiguous; per-recipient amounts persist).
-- Self-reverting. Synthetic fixtures: contacts 'PRUEBA zelle N', phones 5990285xxxx, fake accounts @example.com.
-- Cases:
--   1  one recipient + a DIFFERENT account, no agregar / posicion: nothing written (first recipient intact), the answer asks other person vs correction
--   2  the retry with agregar=true adds the second recipient (not "sin cambios"); both are in force
--   3  amounts: agregar with monto 200 and posicion 1 with monto 100 are stored on their recipients (amount + USD); a later name-only call and a later
--      account-only call keep both amounts
--   4  posicion=1 with the new account corrects the first recipient's account (amount kept); completing a recipient that has no account yet still works
-- =====================================================================
CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990285' || lpad(p_n::text, 4, '0'), 'PRUEBA zelle ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;


CREATE FUNCTION pg_temp.p_z(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(b.position || ':' || coalesce(b.name, '-') || ':' || coalesce(b.zelle_account, '-') || ':' || coalesce(trim_scale(b.amount)::text, '-') || coalesce(b.currency, ''), ' | ' ORDER BY b.position), '')
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = p_conv AND b.status = 'vigente' AND b.beneficiary_type = 'zelle';
$f$;

DO $$
DECLARE c record; a text;
BEGIN
  -- 1 + 2
  SELECT * INTO c FROM pg_temp.p_conv(1);
  SELECT accion INTO a FROM cerebro_guardar_zelle(c.conv, 'Maria Lopez', 'maria@example.com', 'z1a');
  SELECT accion INTO a FROM cerebro_guardar_zelle(c.conv, 'Juan Perez', '5551234567', 'z1b');
  PERFORM pg_temp.p_eq('1 refused', (a LIKE 'NO SE GUARDO NADA:%agregar=true%posicion=1%No se cambio nada.')::text, 'true');
  PERFORM pg_temp.p_eq('1 first intact', pg_temp.p_z(c.conv), '1:Maria Lopez:maria@example.com:-');
  SELECT accion INTO a FROM cerebro_guardar_zelle(c.conv, 'Juan Perez', '5551234567', 'z1c', NULL, 'registrar_beneficiario_zelle', NULL, true);
  PERFORM pg_temp.p_eq('2 retry adds', (a LIKE 'guardado (destinatario 2 de 2): titular Juan Perez%')::text, 'true');
  PERFORM pg_temp.p_eq('2 both in force', pg_temp.p_z(c.conv), '1:Maria Lopez:maria@example.com:- | 2:Juan Perez:5551234567:-');

  -- 3 amounts
  SELECT * INTO c FROM pg_temp.p_conv(2);
  PERFORM cerebro_guardar_zelle(c.conv, 'Pedro Vidal', 'pedro@example.com', 'z3a');
  PERFORM cerebro_guardar_zelle(c.conv, 'Sofia Rivas', 'sofia@example.com', 'z3b', NULL, 'registrar_beneficiario_zelle', NULL, true, 200);
  PERFORM cerebro_guardar_zelle(c.conv, NULL, NULL, 'z3c', NULL, 'registrar_beneficiario_zelle', 1, false, 100);
  PERFORM pg_temp.p_eq('3 amounts stored', pg_temp.p_z(c.conv), '1:Pedro Vidal:pedro@example.com:100USD | 2:Sofia Rivas:sofia@example.com:200USD');
  PERFORM cerebro_guardar_zelle(c.conv, 'Pedro Vidal Gil', 'pedro@example.com', 'z3d');
  PERFORM pg_temp.p_eq('3 name-only call keeps amounts', pg_temp.p_z(c.conv), '1:Pedro Vidal Gil:pedro@example.com:100USD | 2:Sofia Rivas:sofia@example.com:200USD');
  PERFORM cerebro_guardar_zelle(c.conv, NULL, 'sofia.r@example.com', 'z3e', NULL, 'registrar_beneficiario_zelle', 2);
  PERFORM pg_temp.p_eq('3 account correction keeps amounts', pg_temp.p_z(c.conv), '1:Pedro Vidal Gil:pedro@example.com:100USD | 2:-:sofia.r@example.com:200USD');

  -- 4 correction by position, completing
  SELECT * INTO c FROM pg_temp.p_conv(3);
  PERFORM cerebro_guardar_zelle(c.conv, 'Ana Gil', 'ana.mal@example.com', 'z4a', NULL, 'registrar_beneficiario_zelle', NULL, false, 50);
  SELECT accion INTO a FROM cerebro_guardar_zelle(c.conv, NULL, 'ana@example.com', 'z4b', NULL, 'registrar_beneficiario_zelle', 1);
  PERFORM pg_temp.p_eq('4 account corrected', pg_temp.p_z(c.conv), '1:-:ana@example.com:50USD');
  SELECT * INTO c FROM pg_temp.p_conv(4);
  PERFORM cerebro_guardar_zelle(c.conv, 'Luis Mora', NULL, 'z4c');
  SELECT accion INTO a FROM cerebro_guardar_zelle(c.conv, NULL, 'luis@example.com', 'z4d');
  PERFORM pg_temp.p_eq('4 completing a recipient without account', pg_temp.p_z(c.conv), '1:Luis Mora:luis@example.com:-');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
