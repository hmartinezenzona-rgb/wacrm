-- =====================================================================
-- Assertion for migration 259 (burst: re-check before sending). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Fixtures build their own account, user, contacts, conversations, events, executions,
-- memory rows and tool log rows. Run it as: BEGIN; \i burst-recheck-before-send.sql; ROLLBACK;
--
-- Cases:
--   1. cerebro_reclamar_lote records memoria_hasta (max memory id of the session at claim; 0 without memory).
--   2. A newer unclaimed customer event -> bloquear, motivo mensaje_nuevo_durante_el_turno; A's events back to
--      pending (exec/start cleared, retry_count unchanged); this turn's memory rows deleted, older ones kept;
--      the next claim returns A + B together. Calculation tools do not prevent the drop.
--   3. No newer event -> sends (bloquear false), nothing changes.
--   4. The newer event is already claimed by another execution -> sends; A stays processing.
--   5. A logged a write tool -> sends.
--   6. A's batch has an image -> sends.
--   7. No memory baseline (no cerebro_ejecuciones row) -> sends.
--   8. Checks 1-5 keep precedence (bot paused -> bot_pausado, nothing released).
--   9. Grants: service_role executes both functions; anon does not.
-- =====================================================================
CREATE FUNCTION pg_temp.mk_conv(p_user uuid, p_acc uuid, p_phone text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_ct uuid; v_conv uuid;
BEGIN
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (p_user, p_acc, p_phone, 'Burst ' || p_phone) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (p_user, p_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $f$;

CREATE FUNCTION pg_temp.ev(p_conv uuid, p_tipo text, p_texto text) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE v_id bigint;
BEGIN
  INSERT INTO session_events (conversation_id, contact_phone, tipo, contenido, processing_status)
  VALUES (p_conv, '5990025900', p_tipo, p_texto, 'pending') RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

CREATE FUNCTION pg_temp.mem(p_conv uuid, p_tipo text) RETURNS int LANGUAGE plpgsql AS $f$
DECLARE v_id int;
BEGIN
  INSERT INTO cerebro_memoria (session_id, message) VALUES (p_conv::text, jsonb_build_object('type', p_tipo, 'content', 'x'))
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

-- A turn: register the execution, claim the pending events, then the agent writes its two memory rows.
CREATE FUNCTION pg_temp.turno(p_conv uuid, p_exec text, p_registrar boolean DEFAULT true) RETURNS int LANGUAGE plpgsql AS $f$
DECLARE v_n int;
BEGIN
  IF p_registrar THEN
    INSERT INTO cerebro_ejecuciones (execution_id, conversation_id, status, started_at) VALUES (p_exec, p_conv, 'running', now());
  END IF;
  SELECT count(*) INTO v_n FROM cerebro_reclamar_lote(p_conv, p_exec);
  PERFORM pg_temp.mem(p_conv, 'human');
  PERFORM pg_temp.mem(p_conv, 'ai');
  RETURN v_n;
END $f$;

DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_acc  uuid;
  v_hash text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_c    uuid;
  v_a1   bigint; v_a2 bigint; v_b bigint;
  v_old  int;
  v_hasta int;
  v_r    record;
  v_n    int;
  v_ids  bigint[];
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'burst-' || v_user || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'burst account', v_user) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_user, 'burst agent', 'burst-' || v_user || '@test.invalid', v_acc, 'agent');

  -- 1. Baseline at claim.
  v_c := pg_temp.mk_conv(v_user, v_acc, '5990025901');
  PERFORM pg_temp.ev(v_c, 'text', 'hola');
  PERFORM pg_temp.turno(v_c, 'burst-1');
  SELECT memoria_hasta INTO v_hasta FROM cerebro_ejecuciones WHERE execution_id = 'burst-1';
  IF v_hasta IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'case 1: baseline without memory must be 0, got %', v_hasta; END IF;
  v_c := pg_temp.mk_conv(v_user, v_acc, '5990025902');
  v_old := pg_temp.mem(v_c, 'human');
  PERFORM pg_temp.ev(v_c, 'text', 'hola');
  PERFORM pg_temp.turno(v_c, 'burst-1b');
  SELECT memoria_hasta INTO v_hasta FROM cerebro_ejecuciones WHERE execution_id = 'burst-1b';
  IF v_hasta IS DISTINCT FROM v_old THEN RAISE EXCEPTION 'case 1: baseline must be % (last memory row at claim), got %', v_old, v_hasta; END IF;

  -- 2. Drop, release, clean memory, then A + B claimed together.
  v_c := pg_temp.mk_conv(v_user, v_acc, '5990025903');
  v_old := pg_temp.mem(v_c, 'ai');
  v_a1 := pg_temp.ev(v_c, 'text', 'quiero enviar');
  v_a2 := pg_temp.ev(v_c, 'audio', NULL);
  v_n := pg_temp.turno(v_c, 'burst-2');
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 2: A should claim 2 events, got %', v_n; END IF;
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id)
  VALUES ('burst-2:calcular_envio:x', 'calcular_envio', 'burst-2', v_c);
  v_b := pg_temp.ev(v_c, 'text', 'a la tarjeta 1234');
  SELECT * INTO v_r FROM cerebro_valla_de_propiedad(v_c, 'burst-2');
  IF v_r.bloquear IS NOT TRUE OR v_r.motivo IS DISTINCT FROM 'mensaje_nuevo_durante_el_turno' THEN
    RAISE EXCEPTION 'case 2: expected bloquear/mensaje_nuevo_durante_el_turno, got %', to_jsonb(v_r); END IF;
  IF EXISTS (SELECT 1 FROM session_events WHERE id IN (v_a1, v_a2)
              AND (processing_status <> 'pending' OR processing_execution_id IS NOT NULL OR processing_started_at IS NOT NULL
                   OR coalesce(retry_count, 0) <> 0)) THEN
    RAISE EXCEPTION 'case 2: A''s events must be back to pending, clean, retry_count unchanged'; END IF;
  SELECT count(*) INTO v_n FROM cerebro_memoria WHERE session_id = v_c::text;
  IF v_n <> 1 OR NOT EXISTS (SELECT 1 FROM cerebro_memoria WHERE id = v_old) THEN
    RAISE EXCEPTION 'case 2: only the memory row from before the turn must remain, rows: %', v_n; END IF;
  SELECT array_agg(id ORDER BY id) INTO v_ids FROM cerebro_reclamar_lote(v_c, 'burst-2b');
  IF v_ids IS DISTINCT FROM ARRAY[v_a1, v_a2, v_b] THEN
    RAISE EXCEPTION 'case 2: the next claim must return A + B, got %', v_ids; END IF;

  -- 3. No newer event: send, nothing changes.
  v_c := pg_temp.mk_conv(v_user, v_acc, '5990025904');
  v_a1 := pg_temp.ev(v_c, 'text', 'hola');
  PERFORM pg_temp.turno(v_c, 'burst-3');
  SELECT * INTO v_r FROM cerebro_valla_de_propiedad(v_c, 'burst-3');
  IF v_r.bloquear IS NOT FALSE THEN RAISE EXCEPTION 'case 3: without a newer event it must send, got %', to_jsonb(v_r); END IF;
  IF NOT EXISTS (SELECT 1 FROM session_events WHERE id = v_a1 AND processing_status = 'processing' AND processing_execution_id = 'burst-3') THEN
    RAISE EXCEPTION 'case 3: A must stay processing'; END IF;
  SELECT count(*) INTO v_n FROM cerebro_memoria WHERE session_id = v_c::text;
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 3: memory must be untouched, rows: %', v_n; END IF;

  -- 4. The newer event is already claimed by another execution: send.
  v_c := pg_temp.mk_conv(v_user, v_acc, '5990025905');
  v_a1 := pg_temp.ev(v_c, 'text', 'hola');
  PERFORM pg_temp.turno(v_c, 'burst-4');
  PERFORM pg_temp.ev(v_c, 'text', 'otra cosa');
  INSERT INTO cerebro_ejecuciones (execution_id, conversation_id, status, started_at) VALUES ('burst-4b', v_c, 'running', now());
  PERFORM cerebro_reclamar_lote(v_c, 'burst-4b');
  SELECT * INTO v_r FROM cerebro_valla_de_propiedad(v_c, 'burst-4');
  IF v_r.bloquear IS NOT FALSE THEN RAISE EXCEPTION 'case 4: a newer event already claimed must not drop A, got %', to_jsonb(v_r); END IF;
  IF NOT EXISTS (SELECT 1 FROM session_events WHERE id = v_a1 AND processing_execution_id = 'burst-4') THEN
    RAISE EXCEPTION 'case 4: A must stay with its execution'; END IF;

  -- 5. A write tool ran in A's turn: send.
  v_c := pg_temp.mk_conv(v_user, v_acc, '5990025906');
  v_a1 := pg_temp.ev(v_c, 'text', 'su nombre es Ana');
  PERFORM pg_temp.turno(v_c, 'burst-5');
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id)
  VALUES ('burst-5:gestionar_beneficiario:x', 'gestionar_beneficiario', 'burst-5', v_c);
  PERFORM pg_temp.ev(v_c, 'text', 'y el celular');
  SELECT * INTO v_r FROM cerebro_valla_de_propiedad(v_c, 'burst-5');
  IF v_r.bloquear IS NOT FALSE THEN RAISE EXCEPTION 'case 5: a write tool must keep the reply, got %', to_jsonb(v_r); END IF;
  IF NOT EXISTS (SELECT 1 FROM session_events WHERE id = v_a1 AND processing_status = 'processing') THEN
    RAISE EXCEPTION 'case 5: A must stay processing'; END IF;

  -- 6. A's batch has an image (a receipt): send.
  v_c := pg_temp.mk_conv(v_user, v_acc, '5990025907');
  PERFORM pg_temp.ev(v_c, 'image', NULL);
  PERFORM pg_temp.turno(v_c, 'burst-6');
  PERFORM pg_temp.ev(v_c, 'text', 'ahi esta');
  SELECT * INTO v_r FROM cerebro_valla_de_propiedad(v_c, 'burst-6');
  IF v_r.bloquear IS NOT FALSE THEN RAISE EXCEPTION 'case 6: an image in A must keep the reply, got %', to_jsonb(v_r); END IF;

  -- 7. No memory baseline: send.
  v_c := pg_temp.mk_conv(v_user, v_acc, '5990025908');
  PERFORM pg_temp.ev(v_c, 'text', 'hola');
  PERFORM pg_temp.turno(v_c, 'burst-7', false);
  PERFORM pg_temp.ev(v_c, 'text', 'buenas');
  SELECT * INTO v_r FROM cerebro_valla_de_propiedad(v_c, 'burst-7');
  IF v_r.bloquear IS NOT FALSE THEN RAISE EXCEPTION 'case 7: without a baseline it must send, got %', to_jsonb(v_r); END IF;
  SELECT count(*) INTO v_n FROM cerebro_memoria WHERE session_id = v_c::text;
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 7: memory must be untouched, rows: %', v_n; END IF;

  -- 8. Checks 1-5 win: bot paused.
  v_c := pg_temp.mk_conv(v_user, v_acc, '5990025909');
  v_a1 := pg_temp.ev(v_c, 'text', 'hola');
  PERFORM pg_temp.turno(v_c, 'burst-8');
  PERFORM pg_temp.ev(v_c, 'text', 'buenas');
  UPDATE conversations SET ai_autoreply_disabled = true WHERE id = v_c;
  SELECT * INTO v_r FROM cerebro_valla_de_propiedad(v_c, 'burst-8');
  IF v_r.bloquear IS NOT TRUE OR v_r.motivo IS DISTINCT FROM 'bot_pausado' THEN
    RAISE EXCEPTION 'case 8: a paused bot must keep motivo bot_pausado, got %', to_jsonb(v_r); END IF;
  IF NOT EXISTS (SELECT 1 FROM session_events WHERE id = v_a1 AND processing_status = 'processing') THEN
    RAISE EXCEPTION 'case 8: a paused bot must not release A'; END IF;

  -- 9. Grants.
  IF NOT has_function_privilege('service_role', 'public.cerebro_valla_de_propiedad(uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_reclamar_lote(uuid,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_valla_de_propiedad(uuid,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_reclamar_lote(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 9: grants changed'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
