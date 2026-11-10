-- =====================================================================
-- Assertion for migration 134 (daily alert of remesas left open).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- =====================================================================
-- 365 diverts the four technical notification types into notification_digest_items; this assertion checks the
-- emitters' own rows, so the diversion trigger is off for this (rolled back) transaction. The digest has its own
-- assertion (notifications-digest.sql).
DO $digest_off$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zzz_notifications_to_digest' AND tgrelid = 'public.notifications'::regclass) THEN
    ALTER TABLE public.notifications DISABLE TRIGGER zzz_notifications_to_digest;
  END IF;
END $digest_off$;

DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_deal uuid; v_r record; v_body text; v_menciones int;
  c_pipeline CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_lista CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  DELETE FROM cerebro_alertas WHERE clave LIKE 'remesas_viejas:%';
  -- A remesa paid 3 days ago and never closed in the panel (real shape: 1727ef31, 19-Sep).
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900134001', 'Test134 Vieja') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test134', 32500, 'GYD', 'DEPOSITO: 32,500 GYD', 'open') RETURNING id INTO v_deal;
  UPDATE remittance_operations SET created_at = now() - interval '3 days', status = 'ready_to_transfer', quoted_source_amount = 32500 WHERE deal_id = v_deal;
  -- A remesa of today: never in the alert.
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900134002', 'Test134 Nueva') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test134b', 52000, 'GYD', 'DEPOSITO: 52,000 GYD', 'open');

  -- 1. The old one is listed, with its amount and age; today's is not.
  SELECT * INTO v_r FROM cerebro_avisar_remesas_abiertas_viejas(NULL, true);
  IF v_r.viejas < 1 OR v_r.avisos_creados < 1 THEN RAISE EXCEPTION 'case 1: expected an alert, got %', row_to_json(v_r); END IF;
  SELECT body INTO v_body FROM notifications WHERE type = 'remesa_abierta_vieja' AND account_id = v_acc ORDER BY created_at DESC LIMIT 1;
  IF v_body NOT LIKE '%Test134 Vieja%32,500 GYD%3 dias%' THEN RAISE EXCEPTION 'case 1: the old remesa must be listed with amount and age, got %', v_body; END IF;
  IF v_body LIKE '%Test134 Nueva%' THEN RAISE EXCEPTION 'case 1: a remesa of today must not be listed'; END IF;
  RAISE NOTICE 'PASS 1: a remesa open for more than 48 h is listed with amount and age; today''s is not';

  -- 2. Once a day: running again right away creates nothing.
  SELECT * INTO v_r FROM cerebro_avisar_remesas_abiertas_viejas(NULL, true);
  IF v_r.avisos_creados <> 0 THEN RAISE EXCEPTION 'case 2: the alert must not repeat within the day, got %', row_to_json(v_r); END IF;
  RAISE NOTICE 'PASS 2: the alert is sent at most once a day';

  -- 3. Closed in the panel → no longer listed.
  -- (all rows share now() inside this transaction, so count mentions instead of taking "the latest")
  DELETE FROM cerebro_alertas WHERE clave LIKE 'remesas_viejas:%';
  -- only a person in the panel can complete a remesa (automation completions are suppressed)
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE deal_id = v_deal;
  PERFORM set_config('wacrm.origin', '', true);
  SELECT count(*) INTO v_menciones FROM notifications WHERE type = 'remesa_abierta_vieja' AND body LIKE '%Test134 Vieja%';
  SELECT * INTO v_r FROM cerebro_avisar_remesas_abiertas_viejas(NULL, true);
  IF (SELECT count(*) FROM notifications WHERE type = 'remesa_abierta_vieja' AND body LIKE '%Test134 Vieja%') > v_menciones THEN
    RAISE EXCEPTION 'case 3: a completed remesa must not be listed';
  END IF;
  RAISE NOTICE 'PASS 3: a remesa closed in the panel is no longer listed';

  IF has_function_privilege('anon', 'cerebro_avisar_remesas_abiertas_viejas(integer,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 4: anon must not execute it';
  END IF;
  RAISE NOTICE 'PASS 4: not exposed to anon';
END $$;
