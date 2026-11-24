-- Assertion for 389 (self-reverting): the authorship view exists, stays
-- internal, and classifies each author type correctly.
--
--   1 view exists
--   2 anon cannot SELECT it
--   3 authenticated cannot SELECT it
--   4 service_role can SELECT it
--   5 cliente / bot / humano / sistema / indeterminado map correctly
--   6 the contact tags and the human name are attached
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
  v_fails int := 0;
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_tag uuid;
  v_bot uuid; v_sys uuid; v_hum uuid; v_cli uuid; v_unk uuid;
  r record; v_nombre text;
BEGIN
  IF to_regclass('public.v_mensajes_autoria') IS NULL THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 1] the view does not exist';
  END IF;
  IF has_table_privilege('anon', 'public.v_mensajes_autoria', 'SELECT') THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 2] anon can read the view';
  END IF;
  IF has_table_privilege('authenticated', 'public.v_mensajes_autoria', 'SELECT') THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 3] authenticated can read the view';
  END IF;
  IF NOT has_table_privilege('service_role', 'public.v_mensajes_autoria', 'SELECT') THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 4] service_role cannot read the view';
  END IF;

  SELECT p.user_id, p.account_id, p.full_name INTO v_user, v_acc, v_nombre
    FROM public.profiles p WHERE p.user_id IS NOT NULL LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'fixture: no profile'; END IF;

  INSERT INTO public.contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '59900389001', 'test389') RETURNING id INTO v_ct;
  INSERT INTO public.conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  SELECT id INTO v_tag FROM public.tags WHERE lower(name) = 'admin' LIMIT 1;
  IF v_tag IS NOT NULL THEN
    INSERT INTO public.contact_tags (id, contact_id, tag_id)
    VALUES (gen_random_uuid(), v_ct, v_tag);
  END IF;

  INSERT INTO public.messages (conversation_id, sender_type, content_type, content_text, ai_generated, is_panel_action, sender_id)
  VALUES (v_conv, 'customer', 'text', 'hola', false, false, NULL) RETURNING id INTO v_cli;
  INSERT INTO public.messages (conversation_id, sender_type, content_type, content_text, ai_generated, is_panel_action, sender_id)
  VALUES (v_conv, 'agent', 'text', 'bot', true, false, NULL) RETURNING id INTO v_bot;
  INSERT INTO public.messages (conversation_id, sender_type, content_type, content_text, ai_generated, is_panel_action, sender_id)
  VALUES (v_conv, 'agent', 'text', 'humano', false, false, v_user) RETURNING id INTO v_hum;
  INSERT INTO public.messages (conversation_id, sender_type, content_type, content_text, ai_generated, is_panel_action, sender_id)
  VALUES (v_conv, 'agent', 'template', 'alerta', true, false, NULL) RETURNING id INTO v_sys;
  INSERT INTO public.messages (conversation_id, sender_type, content_type, content_text, ai_generated, is_panel_action, sender_id)
  VALUES (v_conv, 'agent', 'text', 'sin autor', false, false, NULL) RETURNING id INTO v_unk;

  FOR r IN SELECT id, autor, autor_nombre, etiquetas FROM public.v_mensajes_autoria
            WHERE conversation_id = v_conv LOOP
    IF r.id = v_cli AND r.autor <> 'cliente' THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 5] customer mapped to %', r.autor;
    ELSIF r.id = v_bot AND r.autor <> 'bot' THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 5] bot mapped to %', r.autor;
    ELSIF r.id = v_hum AND r.autor <> 'humano' THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 5] human mapped to %', r.autor;
    ELSIF r.id = v_sys AND r.autor <> 'sistema' THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 5] template mapped to %', r.autor;
    ELSIF r.id = v_unk AND r.autor <> 'indeterminado' THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 5] unknown mapped to %', r.autor;
    END IF;
    IF r.id = v_hum AND (r.autor_nombre IS DISTINCT FROM v_nombre) THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 6] human name not attached';
    END IF;
    IF v_tag IS NOT NULL AND NOT (r.etiquetas @> '["Admin"]'::jsonb) THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 6] tags not attached: %', r.etiquetas;
    END IF;
  END LOOP;

  IF v_fails > 0 THEN RAISE EXCEPTION 'mensajes-autoria: % case(s) FAILED', v_fails; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
