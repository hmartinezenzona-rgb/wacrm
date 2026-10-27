\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migrations 335 + 336 (Zelle amounts vs. what the operation covers).
-- 336 supersedes 335: recipients are NEVER blocked. When every recipient has an
-- amount, the destination total is their sum, the objective is re-targeted to
-- what that sum needs in GYD, and the reply carries an AVISO with the shortfall.
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Cases:
--   1. first recipient below the cap is saved;
--   2. a second recipient that pushes the sum over the cap is STILL saved and the reply says AVISO;
--   3. the operation's destination total becomes the sum of the recipients;
--   4. cerebro_saldo_operacion reports the exact missing GYD;
--   5. a zero/negative amount keeps the existing error.
-- The cap and the rate are computed with the same functions the migration uses.
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
  v_op uuid;
  v_cap numeric;
  v_half numeric;
  v_msg text;
  v_n int;
  v_sum numeric;
  v_total numeric;
  v_saldo numeric;
  v_dep numeric;
  v_need numeric;
BEGIN
  v_conv := pg_temp.conv_t335('01');
  PERFORM pg_temp.msg_t335(v_conv, '50 a esta 8132940493 y 50 a la otra 954-425-3182');
  PERFORM pg_temp.deposit_t335(v_conv, '10403350000001', 'COMP-335aaaaaaaaaaaaaaa1');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;

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

  -- 2. A second recipient over the cap is STILL saved and the reply carries the AVISO.
  SELECT accion INTO v_msg FROM cerebro_guardar_zelle(v_conv, 'Beto Dos', '9544253182', 't335-2',
    NULL, 'registrar_beneficiario_zelle', NULL, true, (v_cap - v_half + 10));
  IF v_msg NOT LIKE 'guardado%' THEN
    RAISE EXCEPTION 'case 2: the over-cap recipient must still be saved, got %', v_msg; END IF;
  IF v_msg NOT LIKE '%AVISO:%faltan%' THEN
    RAISE EXCEPTION 'case 2b: the reply must carry the AVISO with the shortfall, got %', v_msg; END IF;

  SELECT count(*), sum(b.amount) INTO v_n, v_sum
    FROM remittance_beneficiaries b
   WHERE b.operation_id = v_op AND b.status = 'vigente' AND b.beneficiary_type = 'zelle';
  IF v_n <> 2 OR v_sum <> v_cap + 10 THEN
    RAISE EXCEPTION 'case 2c: expected two recipients summing %, got n=% sum=%', v_cap + 10, v_n, v_sum; END IF;

  -- 3. The operation's destination total is the sum of the recipients.
  SELECT quoted_destination_amount INTO v_total FROM remittance_operations WHERE id = v_op;
  IF v_total <> v_sum THEN
    RAISE EXCEPTION 'case 3: destination total should be %, got %', v_sum, v_total; END IF;

  -- 4. The balance reports the exact missing GYD (needed - deposited).
  SELECT saldo, depositado INTO v_saldo, v_dep FROM cerebro_saldo_operacion(v_op);
  v_need := round(v_sum * coalesce(cerebro_tasa_zelle(floor(v_sum)), 0));
  IF v_saldo IS NULL OR v_saldo <> (v_need - v_dep) OR v_saldo <= 0 THEN
    RAISE EXCEPTION 'case 4: expected saldo % (need % - deposited %), got %', v_need - v_dep, v_need, v_dep, v_saldo; END IF;

  -- 5. Zero or negative amounts keep the pre-existing error.
  SELECT accion INTO v_msg FROM cerebro_guardar_zelle(v_conv, 'Ana Uno', '8132940493', 't335-4',
    NULL, 'registrar_beneficiario_zelle', NULL, false, 0);
  IF v_msg NOT LIKE 'ERROR: el monto de ese destinatario%' THEN
    RAISE EXCEPTION 'case 5: zero amount must keep the existing error, got %', v_msg; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
