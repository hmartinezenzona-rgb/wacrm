-- =====================================================================
-- Assertion for migration 204 (a recharge asked for by AUDIO). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/panel-other-services.md. The recharge rule (cerebro_recarga_en_curso) reads TYPED text only: a customer who
-- asks for a recharge by voice note got his deposit filed as a remesa. The agent understands the audio: its tool calls
-- crm_registrar_numeros_recarga(conv, text, p_abrir => true), which opens the recharge even with no typed keyword and
-- even before any number; an open recharge then counts as "recharge in progress", so the deposit lands on it.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t204(p_tag text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900204' || p_tag, 'test204' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  -- only audio and a greeting: no typed "recarga"
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'audio', NULL, now() - interval '10 minutes'),
    (v_conv, 'customer', 'text', 'hola', now() - interval '9 minutes');
  RETURN v_conv;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.ops_t204(p_conv uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(o.service_type || '/' || o.status || '/' || o.quoted_source_amount::int || '/' ||
           coalesce((SELECT string_agg(b.phone, ',' ORDER BY b.position) FROM remittance_beneficiaries b
                      WHERE b.operation_id = o.id AND b.status = 'vigente' AND b.beneficiary_type = 'recarga'), '-'), ';'), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$$;

DO $$
DECLARE v_conv uuid;
BEGIN
  -- 1. Without the agent's word, an audio-only chat is not a recharge (unchanged).
  v_conv := pg_temp.conv_t204('01');
  PERFORM crm_registrar_numeros_recarga(v_conv, '53821230');
  IF pg_temp.ops_t204(v_conv) <> '' THEN RAISE EXCEPTION 'case 1: nothing must open without the agent, got %', pg_temp.ops_t204(v_conv); END IF;

  -- 2. The agent says it is a recharge (numbers dictated): it opens with them.
  PERFORM crm_registrar_numeros_recarga(v_conv, '5382 1230 y 5345 6789', true);
  IF pg_temp.ops_t204(v_conv) <> 'recarga/collecting_information/0/53821230,53456789' THEN
    RAISE EXCEPTION 'case 2: expected the recharge with both numbers, got %', pg_temp.ops_t204(v_conv); END IF;
  -- and the open recharge now counts as "recharge in progress"
  IF NOT cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 2: an open recharge is a recharge in progress'; END IF;

  -- 3. The deposit lands on it.
  PERFORM cerebro_registrar_deposito(v_conv, 12400, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid, NULL, NULL);
  IF pg_temp.ops_t204(v_conv) <> 'recarga/deposit_verification/12400/53821230,53456789' THEN
    RAISE EXCEPTION 'case 3: the deposit must land on the recharge, got %', pg_temp.ops_t204(v_conv); END IF;

  -- 4. The agent knows it is a recharge before any number: it opens empty, and the deposit lands on it.
  v_conv := pg_temp.conv_t204('04');
  PERFORM crm_registrar_numeros_recarga(v_conv, '', true);
  IF pg_temp.ops_t204(v_conv) <> 'recarga/collecting_information/0/-' THEN
    RAISE EXCEPTION 'case 4: expected an empty open recharge, got %', pg_temp.ops_t204(v_conv); END IF;
  PERFORM cerebro_registrar_deposito(v_conv, 6200, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid, NULL, NULL);
  IF pg_temp.ops_t204(v_conv) <> 'recarga/deposit_verification/6200/-' THEN
    RAISE EXCEPTION 'case 4: the deposit must land on the empty recharge, got %', pg_temp.ops_t204(v_conv); END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
