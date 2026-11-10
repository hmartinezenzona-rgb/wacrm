\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 365 (daily digest for the four technical notification types).
-- Run as  BEGIN; 365; <this file>; ROLLBACK;  or with 365 applied. Self-reverting: ends in
-- RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. RED before 365: cerebro_resumen_diario does not exist.
-- Cases:
--   1  objects: digest function, items table, diverting trigger, type 'resumen_diario' accepted, cron job
--      'resumen-diario-notificaciones' at 12:30 UTC Mon-Sat (08:30 Guyana); grants (service_role only);
--   2  the four technical types stop creating per-run rows: a real emitter (cerebro_avisar_mensajes_fallidos) and direct
--      inserts shaped like the other three leave notifications untouched and queue digest items per profile;
--   3  exemptions: "Nueva promocion de Etecsa detectada" (actionable), chat_atascado, deal_incidencia and
--      conversation_assigned still insert normally;
--   4  the digest: one row per profile, titled with the total, one section per type with events, types with zero omitted,
--      repeated identical lines collapsed "(xN)", at most 5 lines per section then "y N mas";
--   5  a second run emits nothing (items are consumed); with nothing pending nothing is emitted at all;
--   6  items of one account never reach profiles of another account.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t365.fail', (coalesce(nullif(current_setting('t365.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE
    RAISE NOTICE 'ok   [%]', p_label;
  END IF;
END $$;

-- Inserts a notification the way the emitters do: one row per profile of the account that has an auth user.
CREATE OR REPLACE FUNCTION pg_temp.emit(p_acc uuid, p_type text, p_title text, p_body text DEFAULT 'cuerpo') RETURNS void LANGUAGE sql AS $$
  INSERT INTO notifications (account_id, user_id, type, title, body)
  SELECT p_acc, p.user_id, p_type, p_title, p_body
    FROM profiles p WHERE p.account_id = p_acc AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.user_id)
$$;

CREATE OR REPLACE FUNCTION pg_temp.cnt(p_acc uuid, p_type text) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM notifications WHERE account_id = p_acc AND type = p_type
$$;

DO $$
DECLARE
  v_acc uuid; v_other uuid; v_user uuid; v_np int; v_ct uuid; v_conv uuid; v_body text; v_title text;
  v_before int; v_i int; v_rows int; v_other_before int;
BEGIN
  PERFORM pg_temp.chk(to_regprocedure('public.cerebro_resumen_diario()') IS NOT NULL, '1 cerebro_resumen_diario exists');
  IF to_regprocedure('public.cerebro_resumen_diario()') IS NULL THEN
    RAISE EXCEPTION '% expectation(s) failed (migration 365 missing)', coalesce(nullif(current_setting('t365.fail', true), ''), '0');
  END IF;
  PERFORM pg_temp.chk(to_regclass('public.notification_digest_items') IS NOT NULL, '1 items table exists');
  PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.notifications'::regclass AND tgname = 'zzz_notifications_to_digest'), '1 diverting trigger exists');
  PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'resumen-diario-notificaciones'
      AND schedule = '30 12 * * 1-6' AND command = 'SELECT public.cerebro_resumen_diario()' AND active), '1 cron job at 12:30 UTC Mon-Sat');
  PERFORM pg_temp.chk(has_function_privilege('service_role', 'public.cerebro_resumen_diario()', 'EXECUTE')
      AND NOT has_function_privilege('authenticated', 'public.cerebro_resumen_diario()', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.cerebro_resumen_diario()', 'EXECUTE'), '1 digest function: service_role only');
  PERFORM pg_temp.chk(NOT has_table_privilege('authenticated', 'public.notification_digest_items', 'SELECT'), '1 items table is not readable by authenticated');

  SELECT p.account_id, p.user_id INTO v_acc, v_user
    FROM profiles p JOIN auth.users au ON au.id = p.user_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  SELECT count(*) INTO v_np FROM profiles p WHERE p.account_id = v_acc AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.user_id);
  DELETE FROM notification_digest_items;

  -- 5 (empty): nothing pending, nothing emitted
  SELECT count(*) INTO v_before FROM notifications WHERE type = 'resumen_diario';
  PERFORM cerebro_resumen_diario();
  PERFORM pg_temp.chk((SELECT count(*) FROM notifications WHERE type = 'resumen_diario') = v_before, '5 nothing pending -> nothing emitted');

  -- 2: a real emitter (fallidos) and direct inserts for the other types
  SELECT p.user_id INTO v_user FROM profiles p WHERE p.account_id = v_acc LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900365001', 'PRUEBA365') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status) VALUES (v_conv, 'agent', 'text', 'PRUEBA365', 'failed');
  v_before := pg_temp.cnt(v_acc, 'mensaje_fallido');
  PERFORM cerebro_avisar_mensajes_fallidos(6);
  PERFORM pg_temp.chk(pg_temp.cnt(v_acc, 'mensaje_fallido') = v_before, '2 the fallidos emitter leaves notifications untouched');
  PERFORM pg_temp.chk((SELECT count(*) FROM notification_digest_items WHERE account_id = v_acc AND type = 'mensaje_fallido') = v_np AND v_np > 0,
                      '2 ...and queued one item per profile (' || v_np || ')');

  v_before := pg_temp.cnt(v_acc, 'mensaje_perdido') + pg_temp.cnt(v_acc, 'remesa_abierta_vieja') + pg_temp.cnt(v_acc, 'promo_etecsa');
  PERFORM pg_temp.emit(v_acc, 'mensaje_perdido', 'Mensaje de 59900365001 NO llego al CRM (1)');
  PERFORM pg_temp.emit(v_acc, 'remesa_abierta_vieja', '2 remesas abiertas hace mas de 48 h');
  PERFORM pg_temp.emit(v_acc, 'promo_etecsa', 'No se pudo revisar la web de Etecsa');
  PERFORM pg_temp.chk(pg_temp.cnt(v_acc, 'mensaje_perdido') + pg_temp.cnt(v_acc, 'remesa_abierta_vieja') + pg_temp.cnt(v_acc, 'promo_etecsa') = v_before,
                      '2 perdido / remesa vieja / promo failure create no notification rows');

  -- 3: exemptions
  v_before := pg_temp.cnt(v_acc, 'promo_etecsa');
  PERFORM pg_temp.emit(v_acc, 'promo_etecsa', 'Nueva promocion de Etecsa detectada');
  PERFORM pg_temp.chk(pg_temp.cnt(v_acc, 'promo_etecsa') = v_before + v_np, '3 a new promotion still notifies immediately');
  v_before := pg_temp.cnt(v_acc, 'chat_atascado') + pg_temp.cnt(v_acc, 'deal_incidencia') + pg_temp.cnt(v_acc, 'conversation_assigned');
  PERFORM pg_temp.emit(v_acc, 'chat_atascado', 'x esperando');
  PERFORM pg_temp.emit(v_acc, 'deal_incidencia', 'incidencia');
  PERFORM pg_temp.emit(v_acc, 'conversation_assigned', 'asignada');
  PERFORM pg_temp.chk(pg_temp.cnt(v_acc, 'chat_atascado') + pg_temp.cnt(v_acc, 'deal_incidencia') + pg_temp.cnt(v_acc, 'conversation_assigned') = v_before + 3 * v_np,
                      '3 chat_atascado / deal_incidencia / conversation_assigned are untouched');

  -- 4: repeats and the line cap
  PERFORM pg_temp.emit(v_acc, 'mensaje_perdido', 'Mensaje de 59900365001 NO llego al CRM (1)');
  PERFORM pg_temp.emit(v_acc, 'mensaje_perdido', 'Mensaje de 59900365001 NO llego al CRM (1)');
  FOR v_i IN 1..6 LOOP
    PERFORM pg_temp.emit(v_acc, 'remesa_abierta_vieja', 'Remesa distinta ' || v_i);
  END LOOP;

  SELECT count(*) INTO v_other_before FROM notifications WHERE type = 'resumen_diario' AND account_id <> v_acc;
  PERFORM cerebro_resumen_diario();
  SELECT count(*) INTO v_rows FROM notifications WHERE type = 'resumen_diario' AND account_id = v_acc;
  PERFORM pg_temp.chk(v_rows = v_np, '4 one digest row per profile (' || v_rows || '/' || v_np || ')');
  SELECT title, body INTO v_title, v_body FROM notifications WHERE type = 'resumen_diario' AND account_id = v_acc AND user_id = v_user;
  -- events: fallido 1 + perdido 1+2 + remesa 1+6 + promo failure 1 = 12
  PERFORM pg_temp.chk(v_title = 'Resumen tecnico del dia: 12 avisos', '4 title carries the total (' || coalesce(v_title, 'null') || ')');
  PERFORM pg_temp.chk(v_body LIKE '%Mensajes rechazados por WhatsApp: 1%', '4 section fallidos with its count');
  PERFORM pg_temp.chk(v_body LIKE '%Mensajes que no llegaron: 3%', '4 section perdidos counts events');
  PERFORM pg_temp.chk(v_body LIKE '%Remesas abiertas hace mucho: 7%', '4 section remesas counts events');
  PERFORM pg_temp.chk(v_body LIKE '%Revision de promociones de Etecsa: 1%', '4 section promo failure');
  PERFORM pg_temp.chk(v_body LIKE '%NO llego al CRM (1) (x3)%', '4 repeated lines collapse to (x3)');
  PERFORM pg_temp.chk(v_body LIKE '%- y % mas%', '4 sections with more than 5 lines end in "y N mas"');
  PERFORM pg_temp.chk((SELECT count(*) FROM regexp_matches(v_body, E'\n- Remesa', 'g')) <= 5, '4 at most 5 lines per section');

  -- 5: consumed
  PERFORM cerebro_resumen_diario();
  PERFORM pg_temp.chk((SELECT count(*) FROM notifications WHERE type = 'resumen_diario' AND account_id = v_acc) = v_np, '5 a second run emits nothing');
  PERFORM pg_temp.chk((SELECT count(*) FROM notification_digest_items WHERE digested_at IS NULL) = 0, '5 items are marked consumed');

  -- zero-type omission: only a remesa event
  PERFORM pg_temp.emit(v_acc, 'remesa_abierta_vieja', '1 remesa abierta hace mas de 48 h');
  PERFORM cerebro_resumen_diario();
  SELECT title, body INTO v_title, v_body FROM notifications
   WHERE type = 'resumen_diario' AND account_id = v_acc AND user_id = v_user AND title LIKE '%: 1 aviso';
  PERFORM pg_temp.chk(v_title = 'Resumen tecnico del dia: 1 aviso' AND v_body NOT LIKE '%Mensajes%' AND v_body NOT LIKE '%Etecsa%',
                      '4 types with zero events are omitted (' || v_title || ')');

  -- 6: account isolation
  SELECT p.account_id INTO v_other FROM profiles p WHERE p.account_id <> v_acc LIMIT 1;
  IF v_other IS NOT NULL THEN
    PERFORM pg_temp.chk((SELECT count(*) FROM notifications WHERE type = 'resumen_diario' AND account_id = v_other) = v_other_before,
                        '6 other accounts get no digest from these items');
  END IF;

  IF coalesce(nullif(current_setting('t365.fail', true), ''), '0')::int > 0 THEN
    RAISE EXCEPTION '% expectation(s) failed', current_setting('t365.fail', true);
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
