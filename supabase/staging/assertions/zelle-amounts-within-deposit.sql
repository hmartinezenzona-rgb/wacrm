\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 335 (Zelle recipients cannot add up to more dollars than the operation covers).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Cases:
--   1. first recipient below the cap is saved;
--   2. a second recipient that would push the sum over the cap is refused and nothing is written;
--   3. the second recipient within the cap is saved and both sum exactly the cap;
--   4. a zero/negative amount keeps the existing error.
-- The cap is computed with the same function the migration uses, so the rates are not hardcoded.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t335(p_tag text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900335' || p_tag, 'test335' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.msg_t335(p_conv uuid, p_text text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (p_conv, 'customer', 'text', p_text, now() - interval '60 seconds');
$$;

CREATE OR REPLACE FUNCTION pg_temp.deposit_t335(p_conv uuid, p_ref text, p_comp text) RETURNS void LANGUAGE sql AS $$
  SELECT FROM cerebro_registrar_deposito(p_conv, 26000, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid,
    E'DEPOSITO: 26,000 GYD - EXITOSA\nVia: Agente MMG;\nRef: ' || p_ref || E'\n' || p_comp, p_comp);
$$;

DO $$
DECLARE
  v_conv uuid;
  v_cap numeric;
  v_half numeric;
  v_msg text;
  v_n int;
  v_sum numeric;
BEGIN
  v_conv := pg_temp.conv_t335('01');
  PERFORM pg_temp.msg_t335(v_conv, '50 a esta 8132940493 y 50 a la otra 954-425-3182');
  PERFORM pg_temp.deposit_t335(v_conv, '10403350000001', 'COMP-335aaaaaaaaaaaaaaa1');

  SELECT usd INTO v_cap FROM cerebro_zelle_cotizar_gyd(26000);
  IF v_cap IS NULL OR v_cap < 20 THEN
    RAISE EXCEPTION 'case 0: the 26,000 GYD cap did not resolve (%), the fixture has no tiers', v_cap;
  END IF;
  v_half := floor(v_cap / 2);

  -- 1. First recipient within the cap.
  SELECT accion INTO v_msg FROM cerebro_guardar_zelle(v_conv, 'Ana Uno', '8132940493', 't335-1',
    NULL, 'registrar_beneficiario_zelle', NULL, false, v_half);
  IF v_msg NOT LIKE 'guardado%' THEN
    RAISE EXCEPTION 'case 1: the first recipient should be saved, got %', v_msg; END IF;

  -- 2. A second recipient that exceeds the cap is refused and nothing is written.
  SELECT accion INTO v_msg FROM cerebro_guardar_zelle(v_conv, 'Beto Dos', '9544253182', 't335-2',
    NULL, 'registrar_beneficiario_zelle', NULL, true, (v_cap - v_half + 10));
  IF v_msg NOT LIKE 'NO SE GUARDO NADA%' THEN
    RAISE EXCEPTION 'case 2: an over-cap recipient must be refused, got %', v_msg; END IF;
  SELECT count(*), coalesce(sum(b.amount), 0) INTO v_n, v_sum
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = v_conv AND b.status = 'vigente' AND b.beneficiary_type = 'zelle';
  IF v_n <> 1 OR v_sum <> v_half THEN
    RAISE EXCEPTION 'case 2b: nothing should be written, got n=% sum=%', v_n, v_sum; END IF;

  -- 3. The second recipient within the cap is saved.
  SELECT accion INTO v_msg FROM cerebro_guardar_zelle(v_conv, 'Beto Dos', '9544253182', 't335-3',
    NULL, 'registrar_beneficiario_zelle', NULL, true, (v_cap - v_half));
  IF v_msg NOT LIKE 'guardado%' THEN
    RAISE EXCEPTION 'case 3: the second recipient within the cap should be saved, got %', v_msg; END IF;
  SELECT count(*), sum(b.amount) INTO v_n, v_sum
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = v_conv AND b.status = 'vigente' AND b.beneficiary_type = 'zelle';
  IF v_n <> 2 OR v_sum <> v_cap THEN
    RAISE EXCEPTION 'case 3b: expected two recipients summing %, got n=% sum=%', v_cap, v_n, v_sum; END IF;

  -- 4. Zero or negative amounts keep the pre-existing error.
  SELECT accion INTO v_msg FROM cerebro_guardar_zelle(v_conv, 'Ana Uno', '8132940493', 't335-4',
    NULL, 'registrar_beneficiario_zelle', NULL, false, 0);
  IF v_msg NOT LIKE 'ERROR: el monto de ese destinatario%' THEN
    RAISE EXCEPTION 'case 4: zero amount must keep the existing error, got %', v_msg; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
