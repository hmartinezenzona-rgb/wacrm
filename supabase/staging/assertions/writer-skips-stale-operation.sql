\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 399 (the recipient writer never targets an operation that can no longer take a deposit).
-- Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only (contacts 'PRUEBA399', phones 59900399xx).
-- Shape of the production case (2026-11-25, conversation f0dd06de): the Zelle recipient was written on an unfunded
-- operation opened 2 days earlier; 391 then refused the deposit there and opened a second operation.
-- Cases:
--   A  stale unfunded operation (48 h): the writer cancels it with an audit row and opens ONE clean operation, which
--      receives the recipient
--   B  fresh unfunded operation (1 h): unchanged, the writer uses it
--   C  stale operation that holds money: unchanged, the writer uses it
--   D  stale operation in a paused conversation: refuses with the pause text, cancels nothing and opens nothing
--   E  stale operation in incident: unchanged, the writer uses it
--   F  stale operation with a locked quoted_source_amount: unchanged, the writer uses it
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t399.fail', (coalesce(nullif(current_setting('t399.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE
    RAISE NOTICE 'ok   [%]', p_label;
  END IF;
END $$;

-- A synthetic conversation with one open remesa, backdated p_hours.
CREATE OR REPLACE FUNCTION pg_temp.fx(p_tag text, p_hours int, OUT o_conv uuid, OUT o_op uuid) LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900399' || p_tag, 'PRUEBA399' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO o_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency,
                                     quoted_source_amount, created_at)
  VALUES (v_acc, o_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 0, now() - make_interval(hours => p_hours))
  RETURNING id INTO o_op;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.x() RETURNS text LANGUAGE sql AS $$ SELECT 'x' || gen_random_uuid()::text $$;
CREATE OR REPLACE FUNCTION pg_temp.typed(p_conv uuid, p_acct text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, ai_generated, is_panel_action)
  VALUES (p_conv, 'customer', 'text', 'mi zelle es ' || coalesce(p_acct, ''), 'sent', false, false) $$;
CREATE OR REPLACE FUNCTION pg_temp.w_zelle(p_conv uuid, p_acct text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_r text;
BEGIN
  PERFORM pg_temp.typed(p_conv, p_acct);
  SELECT accion INTO v_r FROM cerebro_guardar_zelle(p_conv, 'PRUEBA Titular Tres', p_acct, pg_temp.x());
  RETURN v_r;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.abiertas(p_conv uuid) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM remittance_operations WHERE conversation_id = p_conv AND status NOT IN ('completed', 'cancelled') $$;
CREATE OR REPLACE FUNCTION pg_temp.canceladas(p_conv uuid) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM remittance_operations WHERE conversation_id = p_conv AND status = 'cancelled' $$;
CREATE OR REPLACE FUNCTION pg_temp.audit_cancel(p_conv uuid) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM remittance_admin_audit a JOIN remittance_operations o ON o.id = a.row_id
   WHERE o.conversation_id = p_conv AND a.action = 'agent_operation_cancel'
     AND a.reason LIKE 'open operation too old to take a deposit%' $$;

DO $$
DECLARE
  v_conv uuid; v_op uuid; v_r text; v_ok boolean; v_n int; v_estado text; v_nueva uuid;
BEGIN
  -- A. Stale unfunded operation: cancelled, audited, one clean operation receives the recipient.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('01', 48);
  v_r := pg_temp.w_zelle(v_conv, 'prueba399a@example.com');
  PERFORM pg_temp.chk((SELECT status FROM remittance_operations WHERE id = v_op) = 'cancelled',
                      'A1 the stale operation is cancelled');
  PERFORM pg_temp.chk(pg_temp.canceladas(v_conv) = 1 AND pg_temp.abiertas(v_conv) = 1,
                      'A2 one cancelled and one open (open=' || pg_temp.abiertas(v_conv) || ')');
  PERFORM pg_temp.chk(pg_temp.audit_cancel(v_conv) = 1, 'A3 the cancel is audited');
  SELECT id INTO v_nueva FROM remittance_operations WHERE conversation_id = v_conv AND status NOT IN ('completed', 'cancelled');
  PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_nueva AND zelle_account = 'prueba399a@example.com'),
                      'A4 the recipient is on the open operation');
  PERFORM pg_temp.chk(coalesce(v_r, '') ILIKE '%SE ABRIO UN ENVIO NUEVO%', 'A5 the reply says a new send was opened: ' || coalesce(v_r, 'null'));

  -- B. Fresh operation: unchanged.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('02', 1);
  v_r := pg_temp.w_zelle(v_conv, 'prueba399b@example.com');
  PERFORM pg_temp.chk(pg_temp.canceladas(v_conv) = 0 AND pg_temp.abiertas(v_conv) = 1
                      AND EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND zelle_account = 'prueba399b@example.com'),
                      'B1 a fresh operation is used, nothing cancelled');

  -- C. Stale but holds money: unchanged.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('03', 48);
  UPDATE remittance_operations SET quoted_source_amount = 5000 WHERE id = v_op;
  v_r := pg_temp.w_zelle(v_conv, 'prueba399c@example.com');
  PERFORM pg_temp.chk(pg_temp.canceladas(v_conv) = 0 AND pg_temp.abiertas(v_conv) = 1
                      AND EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND zelle_account = 'prueba399c@example.com'),
                      'C1 an operation with money is used even when old');

  -- D. Paused conversation: refuses, cancels nothing, opens nothing.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('04', 48);
  UPDATE conversations SET ai_autoreply_disabled = true WHERE id = v_conv;
  v_ok := false;
  BEGIN
    PERFORM cerebro_escribir_bloque_beneficiario(v_conv, v_op,
      'ZELLE VARIOS DESTINATARIOS' || E'\n1) Nombre: PRUEBA | Cuenta Zelle: prueba399d@example.com | Recibe: -');
  EXCEPTION WHEN OTHERS THEN v_ok := true;
  END;
  PERFORM pg_temp.chk(v_ok AND pg_temp.canceladas(v_conv) = 0 AND pg_temp.abiertas(v_conv) = 1
                      AND (SELECT status FROM remittance_operations WHERE id = v_op) = 'collecting_information',
                      'D1 paused: nothing cancelled, nothing opened');

  -- E. Stale in incident: unchanged.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('05', 48);
  UPDATE remittance_operations SET status = 'incident' WHERE id = v_op;
  v_r := pg_temp.w_zelle(v_conv, 'prueba399e@example.com');
  PERFORM pg_temp.chk(pg_temp.canceladas(v_conv) = 0 AND pg_temp.abiertas(v_conv) = 1
                      AND EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND zelle_account = 'prueba399e@example.com'),
                      'E1 an incident operation is used');

  -- F. Stale with a locked amount: unchanged. The Zelle tool's own amount guards (335) are not part of this rule, so the
  -- funnel is called directly and only the target decision is asserted.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('06', 48);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('quoted_source_amount', true) WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  PERFORM cerebro_escribir_bloque_beneficiario(v_conv, v_op,
    'ZELLE VARIOS DESTINATARIOS' || E'\n1) Nombre: PRUEBA | Cuenta Zelle: prueba399f@example.com | Recibe: -');
  PERFORM pg_temp.chk(pg_temp.canceladas(v_conv) = 0 AND pg_temp.abiertas(v_conv) = 1
                      AND EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND zelle_account = 'prueba399f@example.com'),
                      'F1 an operation with a locked amount is used');

  v_n := coalesce(nullif(current_setting('t399.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
