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
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_r record; v_body text; v_menciones int;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  DELETE FROM cerebro_alertas WHERE clave LIKE 'remesas_viejas:%';
  -- A remesa paid 3 days ago and never closed in the panel.
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900134001', 'Test134 Vieja') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, created_at)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 32500, now() - interval '3 days') RETURNING id INTO v_op;
  -- A remesa of today: never in the alert.
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900134002', 'Test134 Nueva') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, created_at)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 52000, now());

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
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
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

-- Convention: reaching this point means every case above passed.
DO $$ BEGIN RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'; END $$;
