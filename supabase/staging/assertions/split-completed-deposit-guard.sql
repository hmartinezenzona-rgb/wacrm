\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 367, part 1 (the split tool never opens operations for a deposit a recently completed send consumed).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT). Synthetic fixtures only:
-- contacts 'PRUEBA367', phones 5990367xxxx.
-- Shape of the 2026-11-12 incident: one 25,400 GYD deposit consumed by a recarga completed 1 h ago, then the bot called
-- repartir_envio "zelle 13000, recarga 12400" and the plan path opened two empty operations.
-- Cases:
--   1  deposit 25,400 consumed by an operation completed 1 h ago, split 13,000 + 12,400 -> no operation opened, no plan row, a
--      derivation recorded (conversation handed to a person), the reply says nothing was created / deposit already applied /
--      do not say it is missing, tool log outcome 'derivado'
--   2  same split with the completed operation 10 h ago (outside the 6 h window) -> plans as before (2 empty operations, plan row)
--   3  completed 1 h ago and NO consumed deposit -> plans as before
--   4  the deposit is annulled -> plans as before
--   5  the deposit is smaller than the parts' total (10,000 vs 25,400) -> plans as before
--   6  parts total below the deposit (13,000 + 6,000 vs 25,400) -> guarded (covered)
--   7  an open operation holds the deposit (v_op not null) -> the guard does not run (not the plan path)
-- =====================================================================
CREATE FUNCTION pg_temp.fx(p_n int, p_hours numeric, p_dep numeric, p_anulado boolean DEFAULT false, OUT o_conv uuid, OUT o_done uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990367' || lpad(p_n::text, 4, '0'), 'PRUEBA367 ' || p_n) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO o_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, created_at)
  VALUES (v_acc, o_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 12400, now() - make_interval(hours => p_hours::int + 1))
  RETURNING id INTO o_done;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() - make_interval(secs => p_hours * 3600) WHERE id = o_done;
  PERFORM set_config('wacrm.origin', '', true);
  IF p_dep IS NOT NULL THEN
    INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, operation_id, consumido_en, anulado_en)
    VALUES ('PRUEBA367-' || p_n || '-' || substr(md5(random()::text), 1, 8), p_dep, 'GYD', 'PRUEBA', 'test367', now() - make_interval(secs => p_hours * 3600 + 600),
            o_done, now() - make_interval(secs => p_hours * 3600 + 300), CASE WHEN p_anulado THEN now() ELSE NULL END);
  END IF;
END $f$;

CREATE FUNCTION pg_temp.nops(p_conv uuid) RETURNS int LANGUAGE sql AS $f$ SELECT count(*)::int FROM remittance_operations WHERE conversation_id = p_conv $f$;
CREATE FUNCTION pg_temp.nplan(p_conv uuid) RETURNS int LANGUAGE sql AS $f$ SELECT count(*)::int FROM cerebro_reparto_planeado WHERE conversation_id = p_conv $f$;
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t367.fail', (coalesce(nullif(current_setting('t367.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE RAISE NOTICE 'ok   [%]', p_label; END IF;
END $f$;

DO $$
DECLARE
  c record; v_t text; v_n int; v_h text; v_r text; v_op uuid; v_acc uuid;
BEGIN
  -- 1 guarded
  SELECT * INTO c FROM pg_temp.fx(1, 1, 25400);
  v_t := cerebro_repartir_envio(c.o_conv, 'zelle 13000, recarga 12400', 'e367-1');
  PERFORM pg_temp.chk(pg_temp.nops(c.o_conv) = 1, '1a no operation opened: ' || pg_temp.nops(c.o_conv));
  PERFORM pg_temp.chk(pg_temp.nplan(c.o_conv) = 0, '1b no plan row');
  PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM conversations x WHERE x.id = c.o_conv AND x.ai_autoreply_disabled AND x.ai_handoff_reason = 'deposito_ya_aplicado'), '1c derivation recorded');
  PERFORM pg_temp.chk(v_t ILIKE '%NO SE CREO NADA%' AND v_t ILIKE '%ya se aplico%' AND v_t ILIKE '%no digas que falta%' AND v_t ILIKE '%companero%', '1d reply: ' || coalesce(v_t, 'null'));
  PERFORM pg_temp.chk((SELECT outcome FROM tool_execution_log WHERE conversation_id = c.o_conv AND tool_name = 'repartir_envio') = 'derivado', '1e log outcome derivado');

  -- 2 outside the window
  SELECT * INTO c FROM pg_temp.fx(2, 10, 25400);
  v_t := cerebro_repartir_envio(c.o_conv, 'zelle 13000, recarga 12400', 'e367-2');
  PERFORM pg_temp.chk(pg_temp.nops(c.o_conv) = 3 AND pg_temp.nplan(c.o_conv) = 1 AND v_t LIKE 'Reparto planeado%', '2 outside the window plans as today: ' || coalesce(v_t, 'null'));
  PERFORM pg_temp.chk(NOT EXISTS (SELECT 1 FROM conversations x WHERE x.id = c.o_conv AND x.ai_handoff_reason = 'deposito_ya_aplicado'), '2b no derivation');

  -- 3 no consumed deposit
  SELECT * INTO c FROM pg_temp.fx(3, 1, NULL);
  v_t := cerebro_repartir_envio(c.o_conv, 'zelle 13000, recarga 12400', 'e367-3');
  PERFORM pg_temp.chk(pg_temp.nops(c.o_conv) = 3 AND pg_temp.nplan(c.o_conv) = 1 AND v_t LIKE 'Reparto planeado%', '3 no deposit plans as today: ' || coalesce(v_t, 'null'));

  -- 4 annulled deposit
  SELECT * INTO c FROM pg_temp.fx(4, 1, 25400, true);
  v_t := cerebro_repartir_envio(c.o_conv, 'zelle 13000, recarga 12400', 'e367-4');
  PERFORM pg_temp.chk(pg_temp.nops(c.o_conv) = 3 AND pg_temp.nplan(c.o_conv) = 1, '4 annulled deposit plans as today');

  -- 5 deposit smaller than the parts
  SELECT * INTO c FROM pg_temp.fx(5, 1, 10000);
  v_t := cerebro_repartir_envio(c.o_conv, 'zelle 13000, recarga 12400', 'e367-5');
  PERFORM pg_temp.chk(pg_temp.nops(c.o_conv) = 3 AND pg_temp.nplan(c.o_conv) = 1, '5 smaller deposit plans as today');

  -- 6 parts below the deposit are still covered
  SELECT * INTO c FROM pg_temp.fx(6, 1, 25400);
  v_t := cerebro_repartir_envio(c.o_conv, 'zelle 13000, recarga 6000', 'e367-6');
  PERFORM pg_temp.chk(pg_temp.nops(c.o_conv) = 1 AND pg_temp.nplan(c.o_conv) = 0 AND v_t ILIKE '%NO SE CREO NADA%', '6 covered parts are guarded');

  -- 7 an open operation holds the deposit: not the plan path, the guard stays out
  SELECT * INTO c FROM pg_temp.fx(7, 1, 25400);
  SELECT account_id INTO v_acc FROM conversations WHERE id = c.o_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, c.o_conv, 'collecting_information', 'remesa', 'GYD', 25400) RETURNING id INTO v_op;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, operation_id, consumido_en)
  VALUES ('PRUEBA367-7-open', 25400, 'GYD', 'PRUEBA', 'test367', now(), v_op, now());
  v_t := cerebro_repartir_envio(c.o_conv, 'zelle 13000, recarga 12400', 'e367-7');
  PERFORM pg_temp.chk(v_t NOT ILIKE '%NO SE CREO NADA%' AND NOT EXISTS (SELECT 1 FROM conversations x WHERE x.id = c.o_conv AND x.ai_handoff_reason = 'deposito_ya_aplicado'),
                      '7 open holder: guard does not run: ' || coalesce(v_t, 'null'));

  v_n := coalesce(nullif(current_setting('t367.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
