\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 372 (a planned split keeps its total as the objective; recipient writers and quotes must not shrink it).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA objetivo reparto N', phones 5990372xxxx.
-- Shape of exec 728365 (owner test 2026-11-13): plan recarga 12,400 + zelle 13,000 (objective 25,400 by the 371 hook), then the Zelle
-- recipient is saved with its amount (cerebro_guardar_zelle -> cerebro_fijar_objetivo(sum, 'USD')) and the objective fell to 13,000.
-- Cases:
--   1  plan + objective 25,400, Zelle recipient saved with 50 USD -> objective stays 25,400 (RED before 372: 13,000)
--   2  cerebro_fijar_objetivo with another amount under a plan -> refused with a "NO se fijo" text naming the plan total, objective untouched
--   3  cerebro_fijar_objetivo with the plan total itself -> accepted ("sin cambios"), objective 25,400 (the 371 hook keeps working)
--   4  no plan: a different amount still replaces the objective (previous behaviour kept)
-- =====================================================================

CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990372' || lpad(p_n::text, 4, '0'), 'PRUEBA objetivo reparto ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

-- the turn: the execution started 2 minutes ago, the customer wrote 3 minutes ago (p_text NULL = no customer text), the bot's last reply was 10 minutes ago
CREATE FUNCTION pg_temp.p_turno(p_conv uuid, p_exec text, p_text text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO cerebro_ejecuciones (execution_id, conversation_id, status, started_at, created_at)
  VALUES (p_exec, p_conv, 'running', now() - interval '2 minutes', now() - interval '2 minutes')
  ON CONFLICT (execution_id) DO NOTHING;
  IF NOT EXISTS (SELECT 1 FROM messages WHERE conversation_id = p_conv AND sender_type = 'agent') THEN
    INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
    VALUES (p_conv, 'agent', 'text', 'PRUEBA bot anterior', now() - interval '10 minutes');
  END IF;
  IF p_text IS NOT NULL THEN
    INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
    VALUES (p_conv, 'customer', 'text', p_text, now() - interval '3 minutes');
  END IF;
END $f$;

-- the recarga the numbers wrote this turn: its agreed amount (audit now) with the numbers 6,200 each
CREATE FUNCTION pg_temp.p_recarga(p_conv uuid, p_monto numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_r uuid;
BEGIN
  v_r := _cerebro_op_parte(p_conv, 'recarga', 'agent:registrar_numeros_recarga', 'test shape');
  PERFORM _cerebro_fijar_monto_acordado(v_r, p_monto, 'automation:registrar_numeros_recarga');
  RETURN v_r;
END $f$;

-- what calcular_usd leaves: the via row of the execution, the last quote and the objective (a recarga is open, so it sets one)
CREATE FUNCTION pg_temp.p_cotiza(p_conv uuid, p_exec text, p_via text, p_gyd numeric) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM cerebro_registrar_cotizacion(p_conv, p_gyd, floor(p_gyd / 260), 'USD', 'calcular_usd');
  PERFORM cerebro_registrar_via_cotizada(p_conv, 'calcular_usd', p_via, p_exec, p_gyd);
  PERFORM cerebro_fijar_objetivo(p_conv, floor(p_gyd / 260), 'USD');
END $f$;

CREATE FUNCTION pg_temp.p_turno_completo(p_conv uuid, p_exec text, p_text text, p_via text, p_gyd numeric, p_recarga numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_r uuid;
BEGIN
  PERFORM pg_temp.p_turno(p_conv, p_exec, p_text);
  v_r := pg_temp.p_recarga(p_conv, p_recarga);
  IF p_via IS NOT NULL THEN PERFORM pg_temp.p_cotiza(p_conv, p_exec, p_via, p_gyd); END IF;
  RETURN v_r;
END $f$;

CREATE FUNCTION pg_temp.p_plan(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce((SELECT total_gyd::int::text || ':' || (SELECT string_agg(e ->> 'servicio' || '/' || trim_scale((e ->> 'monto_gyd')::numeric)::text, ';' ORDER BY ord)
                                                           FROM jsonb_array_elements(pl.partes) WITH ORDINALITY t(e, ord))
                     FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = p_conv), '-');
$f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.p_obj(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce((SELECT monto::int::text FROM cerebro_objetivo_envio WHERE conversation_id = p_conv AND cerrado_en IS NULL), '-');
$f$;

-- a planned conversation as the 371 hook leaves it: plan 12,400 + 13,000, objective 25,400
CREATE FUNCTION pg_temp.p_planeada(p_n int, p_exec text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE c record; v_r uuid;
BEGIN
  SELECT * INTO c FROM pg_temp.p_conv(p_n);
  v_r := pg_temp.p_turno_completo(c.conv, p_exec, '2 recargas a 55599180 y 55599181 y tambien un zelle de 50 usd', 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, p_exec);
  RETURN c.conv;
END $f$;

DO $$
DECLARE
  v_conv uuid; v_f record;
BEGIN
  -- 1 exec 728365 shape
  v_conv := pg_temp.p_planeada(1, 'ob-1');
  PERFORM pg_temp.p_eq('1 before', pg_temp.p_plan(v_conv) || '|' || pg_temp.p_obj(v_conv), '25400:recarga/12400;zelle/13000|25400');
  PERFORM cerebro_guardar_zelle(v_conv, 'PRUEBA Juan Perez', 'prueba.objetivo@example.com', 'ob-1b', NULL, 'registrar_beneficiario_zelle', NULL, false, 50);
  PERFORM pg_temp.p_eq('1 plan kept', pg_temp.p_plan(v_conv), '25400:recarga/12400;zelle/13000');
  PERFORM pg_temp.p_eq('1 objective stays the plan total', pg_temp.p_obj(v_conv), '25400');

  -- 2 another amount under a plan
  v_conv := pg_temp.p_planeada(2, 'ob-2');
  SELECT * INTO v_f FROM cerebro_fijar_objetivo(v_conv, 13000, 'GYD');
  PERFORM pg_temp.p_eq('2 refusal text', (v_f.accion LIKE 'NO se fijo%' AND v_f.accion LIKE '%25,400%')::text, 'true');
  PERFORM pg_temp.p_eq('2 objective untouched', pg_temp.p_obj(v_conv), '25400');
  SELECT * INTO v_f FROM cerebro_fijar_objetivo(v_conv, 50, 'USD');
  PERFORM pg_temp.p_eq('2b usd refused too', pg_temp.p_obj(v_conv) || '|' || (v_f.accion LIKE 'NO se fijo%')::text, '25400|true');

  -- 3 the plan total itself
  SELECT * INTO v_f FROM cerebro_fijar_objetivo(v_conv, 25400, 'GYD');
  PERFORM pg_temp.p_eq('3', pg_temp.p_obj(v_conv) || '|' || v_f.accion, '25400|sin cambios, ya estaba fijado');

  -- 4 no plan: replaced as before
  v_conv := pg_temp.p_planeada(4, 'ob-4');
  DELETE FROM cerebro_reparto_planeado WHERE conversation_id = v_conv;
  SELECT * INTO v_f FROM cerebro_fijar_objetivo(v_conv, 13000, 'GYD');
  PERFORM pg_temp.p_eq('4', pg_temp.p_obj(v_conv) || '|' || (v_f.accion LIKE 'objetivo sustituido%')::text, '13000|true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
