-- =====================================================================
-- Assertion for migration 400 (message media metadata). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Builds its own contact/conversation fixtures; account and user
-- come from whatsapp_config + profiles.
--
-- openspec/changes/inbox-media-performance (slice 5a, ADR-6). Eight cases:
--   1. legacy insert (no new columns) -> media_status IS NULL, media_attempts = 0
--   2. media_status = 'bogus' is rejected
--   3. pending row claimed 10 minutes ago -> 'reintentar', attempts + 1
--   4. pending row claimed 1 minute ago -> not returned
--   5. pending row with attempts = 3 -> 'fallida', media_status = 'failed'
--   6. pending row older than 7 days -> 'fallida', error 'meta window expired'
--   7. ready and NULL rows are never touched
--   8. authenticated has no EXECUTE on crm_media_reclamar
-- Run it as: BEGIN; \i messages-media-metadata.sql; ROLLBACK;
-- =====================================================================
\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION pg_temp.m400_msg(
  p_conv uuid,
  p_tag text,
  p_created interval,
  p_status text DEFAULT NULL,
  p_claimed interval DEFAULT NULL,
  p_attempts integer DEFAULT 0
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO messages (
    conversation_id, sender_type, content_type, media_url, message_id, status,
    ai_generated, is_panel_action, created_at,
    media_status, media_claimed_at, media_attempts
  ) VALUES (
    p_conv, 'customer', 'image', 'https://example.invalid/prueba400-' || p_tag || '.jpg',
    'wamid.PRUEBA400-' || p_tag, 'sent', false, false, now() - p_created,
    p_status,
    CASE WHEN p_claimed IS NULL THEN NULL ELSE now() - p_claimed END,
    p_attempts::smallint
  ) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

DO $$
DECLARE
  v_user uuid; v_acc uuid; v_contact uuid; v_conv uuid;
  v_legacy uuid; v_stale uuid; v_fresh uuid; v_exhausted uuid; v_expired uuid;
  v_ready uuid; v_null uuid; v_rejected boolean;
  v_row record;
  v_seen text[] := '{}';
  v_status text; v_error text; v_attempts smallint;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'sin cuenta para la prueba';
  END IF;

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '59900400' || lpad((random() * 9999)::int::text, 4, '0'), 'PRUEBA400')
  RETURNING id INTO v_contact;

  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_contact) RETURNING id INTO v_conv;

  -- 1. legacy shape: no new columns written
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, message_id, status,
                        ai_generated, is_panel_action)
  VALUES (v_conv, 'customer', 'text', 'PRUEBA400 legacy', 'wamid.PRUEBA400-legacy', 'sent', false, false)
  RETURNING id INTO v_legacy;

  SELECT media_status, media_attempts INTO v_status, v_attempts FROM messages WHERE id = v_legacy;
  IF v_status IS NOT NULL THEN
    RAISE EXCEPTION 'FALLO 1: legacy insert got media_status %', v_status;
  END IF;
  IF v_attempts <> 0 THEN
    RAISE EXCEPTION 'FALLO 1: legacy insert got media_attempts %', v_attempts;
  END IF;

  -- 2. an unknown status is rejected by the CHECK
  BEGIN
    INSERT INTO messages (conversation_id, sender_type, content_type, message_id, status,
                          ai_generated, is_panel_action, media_status)
    VALUES (v_conv, 'customer', 'image', 'wamid.PRUEBA400-bogus', 'sent', false, false, 'bogus');
    v_rejected := false;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FALLO 2: media_status = bogus was accepted';
  END IF;

  -- 3..6. the rows the function must act on
  v_stale     := pg_temp.m400_msg(v_conv, 'stale',     interval '1 hour',  'pending', interval '10 minutes', 0);
  v_fresh     := pg_temp.m400_msg(v_conv, 'fresh',     interval '1 hour',  'pending', interval '1 minute',   0);
  v_exhausted := pg_temp.m400_msg(v_conv, 'exhausted', interval '1 hour',  'pending', interval '10 minutes', 3);
  v_expired   := pg_temp.m400_msg(v_conv, 'expired',   interval '8 days',  'pending', interval '10 minutes', 0);
  v_ready     := pg_temp.m400_msg(v_conv, 'ready',     interval '1 hour',  'ready',   NULL,                 0);
  v_null      := pg_temp.m400_msg(v_conv, 'nullrow',   interval '1 hour',  NULL,      NULL,                 0);

  FOR v_row IN SELECT * FROM public.crm_media_reclamar(50, interval '5 minutes') LOOP
    IF v_row.id IN (v_stale, v_fresh, v_exhausted, v_expired, v_ready, v_null, v_legacy) THEN
      v_seen := array_append(v_seen, v_row.id || ':' || v_row.accion);
    END IF;
  END LOOP;

  IF NOT (v_stale::text || ':reintentar' = ANY (v_seen)) THEN
    RAISE EXCEPTION 'FALLO 3: a row claimed 10 minutes ago was not returned as reintentar: %', v_seen;
  END IF;
  SELECT media_attempts INTO v_attempts FROM messages WHERE id = v_stale;
  IF v_attempts <> 1 THEN
    RAISE EXCEPTION 'FALLO 3: attempts not incremented, got %', v_attempts;
  END IF;

  IF (v_fresh::text || ':reintentar' = ANY (v_seen)) THEN
    RAISE EXCEPTION 'FALLO 4: a row claimed 1 minute ago was returned';
  END IF;

  IF NOT (v_exhausted::text || ':fallida' = ANY (v_seen)) THEN
    RAISE EXCEPTION 'FALLO 5: an exhausted row was not returned as fallida: %', v_seen;
  END IF;
  SELECT media_status, media_error INTO v_status, v_error FROM messages WHERE id = v_exhausted;
  IF v_status <> 'failed' THEN
    RAISE EXCEPTION 'FALLO 5: exhausted row is %, not failed', v_status;
  END IF;

  IF NOT (v_expired::text || ':fallida' = ANY (v_seen)) THEN
    RAISE EXCEPTION 'FALLO 6: an 8-day-old row was not returned as fallida: %', v_seen;
  END IF;
  SELECT media_status, media_error INTO v_status, v_error FROM messages WHERE id = v_expired;
  IF v_status <> 'failed' OR v_error <> 'meta window expired' THEN
    RAISE EXCEPTION 'FALLO 6: expired row is % / %', v_status, v_error;
  END IF;

  IF (v_ready::text || ':reintentar' = ANY (v_seen)) OR (v_ready::text || ':fallida' = ANY (v_seen)) THEN
    RAISE EXCEPTION 'FALLO 7: a ready row was touched: %', v_seen;
  END IF;
  IF (v_null::text || ':reintentar' = ANY (v_seen)) OR (v_null::text || ':fallida' = ANY (v_seen)) THEN
    RAISE EXCEPTION 'FALLO 7: a NULL-status row was touched: %', v_seen;
  END IF;
  SELECT media_attempts INTO v_attempts FROM messages WHERE id = v_ready;
  IF v_attempts <> 0 THEN
    RAISE EXCEPTION 'FALLO 7: ready row attempts changed to %', v_attempts;
  END IF;

  IF has_function_privilege('authenticated', 'public.crm_media_reclamar(int, interval)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FALLO 8: authenticated can execute crm_media_reclamar';
  END IF;
  IF has_function_privilege('anon', 'public.crm_media_reclamar(int, interval)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FALLO 8: anon can execute crm_media_reclamar';
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
