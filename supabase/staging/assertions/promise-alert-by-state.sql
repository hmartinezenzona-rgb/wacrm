-- 362: the AVISO PROMESA alert is judged by saved STATE about 2 minutes after the message.
-- Synthetic PRUEBA fixtures, rolled back. The evaluation step is called directly: cerebro_promesa_evaluar(p_now).
-- Cases:
--   A  off-hours notice never counts as a claim (no candidate, no alert); a real claim next to it still does
--   B  claim + beneficiary saved 40 s after the message             -> closed as saved, no alert
--   C  claim + beneficiary saved 18 min before (recap "Anotado")    -> no alert
--   D  claim + other writers: reparto_auto beneficiary, operation touched, Zelle parcial row, deposit receipt,
--      reparto plan                                                  -> no alert
--   E  claim + only a read-only tool logged, nothing saved          -> exactly one alert and one memory note
--   F  claim + nothing saved, evaluated twice                       -> exactly one alert
--   G  claim + data saved 2 h before / only after evaluation time   -> alert (outside the window)
--   H  inserting the message never alerts; a candidate not yet due stays pending
CREATE FUNCTION pg_temp.pf_conv(p_owner uuid, p_acc uuid, p_n integer) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_ct uuid; v_cv uuid;
BEGIN
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), p_owner, '5990036' || lpad(p_n::text, 4, '0'), 'PRUEBA 362 ' || p_n, p_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), p_owner, v_ct, p_acc) RETURNING id INTO v_cv;
  RETURN v_cv;
END $f$;

CREATE FUNCTION pg_temp.pf_msg(p_conv uuid, p_text text, p_at timestamptz) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, ai_generated, status, created_at)
  VALUES (p_conv, 'agent', 'text', p_text, true, 'sent', p_at) RETURNING id INTO v;
  RETURN v;
END $f$;

-- old operation (3 h before) so only the row under test can fall inside the window
CREATE FUNCTION pg_temp.pf_op(p_acc uuid, p_conv uuid, p_at timestamptz) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
  INSERT INTO remittance_operations (account_id, conversation_id, created_at, updated_at)
  VALUES (p_acc, p_conv, p_at - interval '3 hours', p_at - interval '3 hours') RETURNING id INTO v;
  RETURN v;
END $f$;

CREATE FUNCTION pg_temp.pf_alerts(p_conv uuid) RETURNS integer LANGUAGE sql AS $f$
  SELECT count(*)::integer FROM message_outbox WHERE conversation_id = p_conv AND payload ->> 'text' LIKE 'AVISO PROMESA%';
$f$;

CREATE FUNCTION pg_temp.pf_notes(p_conv uuid) RETURNS integer LANGUAGE sql AS $f$
  SELECT count(*)::integer FROM cerebro_memoria WHERE session_id = p_conv::text AND message ->> 'content' LIKE '[CONTEXTO DEL SISTEMA%';
$f$;

DO $$
DECLARE
  v_owner uuid := gen_random_uuid();
  v_hash constant text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_tag uuid; v_ct_admin uuid;
  v_t timestamptz := now() - interval '30 minutes';   -- message time of every case
  v_eval timestamptz := now() - interval '28 minutes'; -- v_t + 2 min
  v_claim constant text := 'Anotado el celular, gracias.';
  v_off constant text := 'Estamos fuera de horario, pero queda registrado y se procesa a partir de las 9:00am (hora de Guyana).';
  a1 uuid; a2 uuid; b uuid; c uuid; d1 uuid; d2 uuid; d3 uuid; d4 uuid; d5 uuid; e uuid; f uuid; g1 uuid; g2 uuid; h uuid;
  v_op uuid; v_m uuid; v_fail text := '';
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'prom-362-' || v_owner || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'promesa 362', v_owner) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner, 'prom 362', 'prom-362-' || v_owner || '@test.invalid', v_acc, 'owner');
  SELECT id INTO v_tag FROM tags WHERE lower(name) = 'admin' LIMIT 1;
  IF v_tag IS NULL THEN
    INSERT INTO tags (user_id, name, color) VALUES (v_owner, 'Admin', '#ff0000') RETURNING id INTO v_tag;
  END IF;
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner, '59900362999', 'ADMIN 362', v_acc) RETURNING id INTO v_ct_admin;
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_ct_admin, v_tag);

  a1 := pg_temp.pf_conv(v_owner, v_acc, 1);  a2 := pg_temp.pf_conv(v_owner, v_acc, 2);
  b  := pg_temp.pf_conv(v_owner, v_acc, 3);  c  := pg_temp.pf_conv(v_owner, v_acc, 4);
  d1 := pg_temp.pf_conv(v_owner, v_acc, 5);  d2 := pg_temp.pf_conv(v_owner, v_acc, 6);
  d3 := pg_temp.pf_conv(v_owner, v_acc, 7);  d4 := pg_temp.pf_conv(v_owner, v_acc, 8);
  d5 := pg_temp.pf_conv(v_owner, v_acc, 9);  e  := pg_temp.pf_conv(v_owner, v_acc, 10);
  f  := pg_temp.pf_conv(v_owner, v_acc, 11); g1 := pg_temp.pf_conv(v_owner, v_acc, 12);
  g2 := pg_temp.pf_conv(v_owner, v_acc, 13); h  := pg_temp.pf_conv(v_owner, v_acc, 14);

  -- messages (the insert only records candidates)
  PERFORM pg_temp.pf_msg(a1, v_off, v_t);
  PERFORM pg_temp.pf_msg(a2, v_off || ' Anotado el celular.', v_t);
  PERFORM pg_temp.pf_msg(b, v_claim, v_t);  PERFORM pg_temp.pf_msg(c, v_claim, v_t);
  PERFORM pg_temp.pf_msg(d1, v_claim, v_t); PERFORM pg_temp.pf_msg(d2, v_claim, v_t);
  PERFORM pg_temp.pf_msg(d3, v_claim, v_t); PERFORM pg_temp.pf_msg(d4, v_claim, v_t);
  PERFORM pg_temp.pf_msg(d5, v_claim, v_t); PERFORM pg_temp.pf_msg(e, v_claim, v_t);
  PERFORM pg_temp.pf_msg(f, v_claim, v_t);  PERFORM pg_temp.pf_msg(g1, v_claim, v_t);
  PERFORM pg_temp.pf_msg(g2, v_claim, v_t);
  PERFORM pg_temp.pf_msg(h, v_claim, now());   -- not yet due at v_eval

  -- H1: the insert itself never alerts
  IF (SELECT sum(pg_temp.pf_alerts(x))::integer FROM unnest(ARRAY[b, c, d1, e, f, g1, h]) x) <> 0 THEN v_fail := v_fail || ' H1:alert-at-insert'; END IF;

  -- saved state. App triggers that touch updated_at stamp the real now(), which is after v_eval and therefore
  -- outside the window, so only the explicit timestamps below can satisfy it.
  -- B: beneficiary saved 40 s after
  v_op := pg_temp.pf_op(v_acc, b, v_t);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, source, created_at) VALUES (v_op, 'cuban_card', 'tool', v_t + interval '40 seconds');
  -- C: beneficiary saved 18 min before (recap)
  v_op := pg_temp.pf_op(v_acc, c, v_t);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, source, created_at) VALUES (v_op, 'cuban_card', 'tool', v_t - interval '18 minutes');
  -- D1 automatic reparto path, D2 Zelle parcial row, D3 deposit receipt, D4 operation touched, D5 reparto plan
  v_op := pg_temp.pf_op(v_acc, d1, v_t);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, source, created_at) VALUES (v_op, 'cuban_card', 'reparto_auto', v_t + interval '30 seconds');
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, zelle_nombre, actualizado) VALUES (d2, 'PRUEBA', v_t - interval '20 seconds');
  v_op := pg_temp.pf_op(v_acc, d3, v_t);
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, source, created_at) VALUES (v_op, d3, 'bot', v_t - interval '10 seconds');
  INSERT INTO remittance_operations (account_id, conversation_id, created_at, updated_at)
  VALUES (v_acc, d4, v_t - interval '3 hours', v_t + interval '20 seconds');
  INSERT INTO cerebro_reparto_planeado (conversation_id, partes, total_gyd, creado_at) VALUES (d5, '[]'::jsonb, 100, v_t - interval '15 seconds');
  -- G1: saved 2 h before; G2: saved only after the evaluation time
  v_op := pg_temp.pf_op(v_acc, g1, v_t);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, source, created_at) VALUES (v_op, 'cuban_card', 'tool', v_t - interval '2 hours');
  v_op := pg_temp.pf_op(v_acc, g2, v_t);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, source, created_at) VALUES (v_op, 'cuban_card', 'tool', v_eval + interval '5 minutes');
  -- E: read-only tool logged in the turn, nothing saved
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, outcome, created_at)
  VALUES ('prueba-362-' || gen_random_uuid(), 'calcular_usd', 'prueba-362', e, 'ok', v_t + interval '20 seconds');

  -- H2: a message that is not yet due stays pending
  PERFORM cerebro_promesa_evaluar(v_eval);
  IF (SELECT status FROM cerebro_promesa_candidatas WHERE conversation_id = h) IS DISTINCT FROM 'pending' THEN v_fail := v_fail || ' H2:not-pending'; END IF;

  -- A: no candidate for the off-hours notice, a candidate for the mixed one
  IF EXISTS (SELECT 1 FROM cerebro_promesa_candidatas WHERE conversation_id = a1) THEN v_fail := v_fail || ' A1:candidate'; END IF;
  IF pg_temp.pf_alerts(a1) <> 0 THEN v_fail := v_fail || ' A2:alert'; END IF;
  IF NOT EXISTS (SELECT 1 FROM cerebro_promesa_candidatas WHERE conversation_id = a2) THEN v_fail := v_fail || ' A3:mixed-no-candidate'; END IF;
  IF cerebro_texto_promete(v_off) THEN v_fail := v_fail || ' A4:texto-off'; END IF;
  IF NOT cerebro_texto_promete(v_claim) THEN v_fail := v_fail || ' A5:texto-claim'; END IF;

  -- B, C, D: saved -> closed silently
  IF pg_temp.pf_alerts(b) <> 0 OR (SELECT status FROM cerebro_promesa_candidatas WHERE conversation_id = b) IS DISTINCT FROM 'saved' THEN v_fail := v_fail || ' B:saved-after'; END IF;
  IF pg_temp.pf_alerts(c) <> 0 OR (SELECT status FROM cerebro_promesa_candidatas WHERE conversation_id = c) IS DISTINCT FROM 'saved' THEN v_fail := v_fail || ' C:recap'; END IF;
  IF pg_temp.pf_alerts(d1) <> 0 OR (SELECT status FROM cerebro_promesa_candidatas WHERE conversation_id = d1) IS DISTINCT FROM 'saved' THEN v_fail := v_fail || ' D1:reparto-auto'; END IF;
  IF pg_temp.pf_alerts(d2) <> 0 OR (SELECT status FROM cerebro_promesa_candidatas WHERE conversation_id = d2) IS DISTINCT FROM 'saved' THEN v_fail := v_fail || ' D2:zelle-parcial'; END IF;
  IF pg_temp.pf_alerts(d3) <> 0 OR (SELECT status FROM cerebro_promesa_candidatas WHERE conversation_id = d3) IS DISTINCT FROM 'saved' THEN v_fail := v_fail || ' D3:receipt'; END IF;
  IF pg_temp.pf_alerts(d4) <> 0 OR (SELECT status FROM cerebro_promesa_candidatas WHERE conversation_id = d4) IS DISTINCT FROM 'saved' THEN v_fail := v_fail || ' D4:op-touched'; END IF;
  IF pg_temp.pf_alerts(d5) <> 0 OR (SELECT status FROM cerebro_promesa_candidatas WHERE conversation_id = d5) IS DISTINCT FROM 'saved' THEN v_fail := v_fail || ' D5:reparto-plan'; END IF;

  -- E, F, G: nothing saved in the window -> exactly one alert (and one memory note)
  IF pg_temp.pf_alerts(e) <> 1 OR pg_temp.pf_notes(e) <> 1 THEN v_fail := v_fail || ' E:read-only-tool(' || pg_temp.pf_alerts(e) || '/' || pg_temp.pf_notes(e) || ')'; END IF;
  IF pg_temp.pf_alerts(f) <> 1 THEN v_fail := v_fail || ' F1:nothing(' || pg_temp.pf_alerts(f) || ')'; END IF;
  IF pg_temp.pf_alerts(g1) <> 1 THEN v_fail := v_fail || ' G1:saved-2h-before'; END IF;
  IF pg_temp.pf_alerts(g2) <> 1 THEN v_fail := v_fail || ' G2:saved-after-eval'; END IF;
  IF pg_temp.pf_alerts(a2) <> 1 THEN v_fail := v_fail || ' A6:mixed-alert'; END IF;

  -- F2: evaluating again does not alert twice; the case table and the note stay single
  PERFORM cerebro_promesa_evaluar(v_eval);
  PERFORM cerebro_promesa_evaluar(v_eval + interval '1 minute');
  IF pg_temp.pf_alerts(f) <> 1 OR pg_temp.pf_notes(f) <> 1 THEN v_fail := v_fail || ' F2:twice'; END IF;
  IF (SELECT count(*) FROM cerebro_promesas_sin_escritura WHERE conversation_id = f) <> 1 THEN v_fail := v_fail || ' F3:case-rows'; END IF;
  IF pg_temp.pf_alerts(b) + pg_temp.pf_alerts(c) <> 0 THEN v_fail := v_fail || ' F4:saved-reopened'; END IF;

  -- the cron job exists
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'evaluar-promesas' AND command LIKE '%cerebro_promesa_evaluar%') THEN v_fail := v_fail || ' J:cron'; END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
