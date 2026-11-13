\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 373 (a quote computed by a calculator tool is stored as the conversation's agreed quote).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT). Load 372 first.
-- Synthetic fixtures only: contacts 'PRUEBA cotizacion tool N', phones 5990373xxxx.
-- The tools run as the n8n nodes do: cerebro_registrar_cotizacion + cerebro_registrar_via_cotizada (+ cerebro_fijar_objetivo for calcular_usd).
-- Cases:
--   1  one quote (Zelle 13,000 = 50 USD) -> cerebro_cotizacion_vigente 13,000, text '*50 USD*' (the shape the panel line reads), execution stored
--   2  a re-quote in the same execution, same service, other amount -> the newest wins
--   3  two different services in one execution (comparison) -> no agreed quote and no objective from that turn
--   4  a later execution quotes one service again -> agreed again (not read as a comparison)
--   5  a plan exists (12,400 + 13,000): the quote of one part is stored as the plan total 25,400, no destination text
--   6  an older parsed quote (execution NULL) is replaced by the tool quote
--   7  no service (via) or no GYD origin -> nothing stored
--   8  the agreed quote of a closed send is not valid for the next one (cerebro_cotizacion_vigente keeps its rule)
-- =====================================================================

CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990373' || lpad(p_n::text, 4, '0'), 'PRUEBA cotizacion tool ' || p_n, v_acc) RETURNING id INTO v_ct;
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
  -- the node's order: objective first, then the quote, then the via row
  PERFORM cerebro_fijar_objetivo(p_conv, floor(p_gyd / 260), 'USD');
  PERFORM cerebro_registrar_cotizacion(p_conv, p_gyd, floor(p_gyd / 260), 'USD', 'calcular_usd');
  PERFORM cerebro_registrar_via_cotizada(p_conv, 'calcular_usd', p_via, p_exec, p_gyd);
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

-- the agreed quote as the panel and the deposit check read it: valid GYD | text | execution
CREATE FUNCTION pg_temp.p_cot(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(cerebro_cotizacion_vigente(p_conv)::int::text, '-') || '|'
      || coalesce((SELECT (regexp_match(c.texto, '\*([0-9][0-9,]*(?:\.[0-9]+)?) (CUP|USD)\*', 'i'))[1] || ' ' || (regexp_match(c.texto, '\*([0-9][0-9,]*(?:\.[0-9]+)?) (CUP|USD)\*', 'i'))[2]
                     FROM cerebro_cotizacion c WHERE c.conversation_id = p_conv), '-') || '|'
      || coalesce((SELECT c.ejecucion FROM cerebro_cotizacion c WHERE c.conversation_id = p_conv), '-');
$f$;

DO $$
DECLARE
  c record; v_r uuid;
  c_txt constant text := '2 recargas a 55599180 y 55599181 y tambien un zelle de 50 usd';
BEGIN
  -- 1 one quote
  SELECT * INTO c FROM pg_temp.p_conv(1);
  v_r := pg_temp.p_turno_completo(c.conv, 'ct-1', c_txt, NULL, NULL, 12400);
  PERFORM pg_temp.p_eq('1 before', pg_temp.p_cot(c.conv), '-|-|-');
  PERFORM pg_temp.p_cotiza(c.conv, 'ct-1', 'zelle', 13000);
  PERFORM pg_temp.p_eq('1', pg_temp.p_cot(c.conv), '13000|50 USD|ct-1');

  -- 2 re-quote, same execution and service
  PERFORM pg_temp.p_cotiza(c.conv, 'ct-1', 'zelle', 13500);
  PERFORM pg_temp.p_eq('2', pg_temp.p_cot(c.conv), '13500|51 USD|ct-1');

  -- 3 comparison: another service in the same execution
  SELECT * INTO c FROM pg_temp.p_conv(3);
  v_r := pg_temp.p_turno_completo(c.conv, 'ct-3', c_txt, 'zelle', 13000, 12400);
  PERFORM pg_temp.p_eq('3 first quote', pg_temp.p_cot(c.conv) || '|' || pg_temp.p_obj(c.conv), '13000|50 USD|ct-3|13000');
  PERFORM pg_temp.p_cotiza(c.conv, 'ct-3', 'clasica', 13780);
  PERFORM pg_temp.p_eq('3 comparison agrees nothing', pg_temp.p_cot(c.conv) || '|' || pg_temp.p_obj(c.conv), '-|-|-|-');

  -- 4 next execution, one service
  PERFORM pg_temp.p_turno(c.conv, 'ct-4', 'mejor zelle');
  PERFORM pg_temp.p_cotiza(c.conv, 'ct-4', 'zelle', 13000);
  PERFORM pg_temp.p_eq('4', pg_temp.p_cot(c.conv), '13000|50 USD|ct-4');

  -- 5 plan: the quote of one part is the plan total
  SELECT * INTO c FROM pg_temp.p_conv(5);
  v_r := pg_temp.p_turno_completo(c.conv, 'ct-5', c_txt, 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'ct-5');
  PERFORM pg_temp.p_eq('5 plan', pg_temp.p_plan(c.conv), '25400:recarga/12400;zelle/13000');
  PERFORM pg_temp.p_cotiza(c.conv, 'ct-5', 'zelle', 13000);
  PERFORM pg_temp.p_eq('5', pg_temp.p_cot(c.conv) || '|' || pg_temp.p_obj(c.conv), '25400|-|ct-5|25400');

  -- 6 an older parsed quote is replaced
  SELECT * INTO c FROM pg_temp.p_conv(6);
  v_r := pg_temp.p_turno_completo(c.conv, 'ct-6', c_txt, NULL, NULL, 12400);
  INSERT INTO cerebro_cotizacion (conversation_id, gyd, texto, cotizado_en) VALUES (c.conv, 20000, 'Por Zelle son *20,000 GYD*', now() - interval '1 hour');
  PERFORM pg_temp.p_eq('6 parsed', pg_temp.p_cot(c.conv), '20000|-|-');
  PERFORM pg_temp.p_cotiza(c.conv, 'ct-6', 'zelle', 13000);
  PERFORM pg_temp.p_eq('6 tool wins', pg_temp.p_cot(c.conv), '13000|50 USD|ct-6');

  -- 7 no service / no GYD origin
  SELECT * INTO c FROM pg_temp.p_conv(7);
  v_r := pg_temp.p_turno_completo(c.conv, 'ct-7', c_txt, NULL, NULL, 12400);
  PERFORM cerebro_registrar_cotizacion(c.conv, 13000, 50, 'USD', 'calcular_usd');
  PERFORM cerebro_registrar_via_cotizada(c.conv, 'calcular_usd', NULL, 'ct-7', 13000);
  PERFORM pg_temp.p_eq('7 no via', pg_temp.p_cot(c.conv), '-|-|-');
  PERFORM cerebro_registrar_via_cotizada(c.conv, 'calcular_envio', 'cuban_card', 'ct-7', NULL);
  PERFORM pg_temp.p_eq('7 no gyd origin', pg_temp.p_cot(c.conv), '-|-|-');

  -- 8 a send closed after the quote: the quote is no longer valid
  SELECT * INTO c FROM pg_temp.p_conv(8);
  v_r := pg_temp.p_turno_completo(c.conv, 'ct-8', c_txt, 'zelle', 13000, 12400);
  PERFORM pg_temp.p_eq('8 before', pg_temp.p_cot(c.conv), '13000|50 USD|ct-8');
  UPDATE remittance_operations SET status = 'cancelled', cancelled_at = now() + interval '1 minute' WHERE id = v_r;
  PERFORM pg_temp.p_eq('8 closed send', (SELECT coalesce(cerebro_cotizacion_vigente(c.conv)::text, '-')), '-');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
