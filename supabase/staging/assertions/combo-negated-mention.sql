\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 246 (a negated "combo" is not a combo order).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Production 2026-10-19 (conversation c2bb35c0): the customer pasted Zelle payee instructions ending in
-- "NO ESCRIBIR NADA DE CUBA REMESAS NI COMBO ECT"; cerebro_combo_en_curso matched the bare word and the deposit opened a
-- combo operation. Rule asserted: a mention negated in the same clause of the same message does not count; any other
-- mention still does, per message. odd/tasks/combo-negated-mention.md.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t246(p_tag text, p_texts text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_i int := 0; v_t text;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;  -- not from conversations: staging can have none after a reset
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900246' || p_tag, 'test246' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  FOREACH v_t IN ARRAY p_texts LOOP
    v_i := v_i + 1;
    INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
    VALUES (v_conv, 'customer', 'text', v_t, now() - make_interval(mins => 30 - v_i));
  END LOOP;
  RETURN v_conv;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.ops_t246(p_conv uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(o.service_type || '/' || o.status || '/' || o.quoted_source_amount::int, ';' ORDER BY o.created_at, o.service_type), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$$;

DO $$
DECLARE
  v_conv uuid; v_acc uuid; v_ct uuid;
  c_verif constant uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  c_yoandy constant text := E'786-295-5183\n\nSantialv LLC \n\n⚠️MUY IMPORTANTE NO LLAMAR NI ESCRIBIR AL NUMERO X FAVOR ⚠️\n\n'
                            || E'⚠️NO ESCRIBIR NADA DE CUBA REMESAS NI COMBO ECT ⚠️';
BEGIN
  -- 1. The production sequence: the pasted instructions alone are not a combo order...
  v_conv := pg_temp.conv_t246('01', ARRAY[c_yoandy]);
  IF cerebro_combo_en_curso(v_conv) THEN
    RAISE EXCEPTION 'case 1: a negated "combo" in pasted Zelle instructions must not be a combo in progress'; END IF;
  -- ... and the receipt that follows opens a remesa, not a combo.
  PERFORM cerebro_registrar_deposito(v_conv, 28600, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t246(v_conv) <> 'remesa/deposit_verification/28600' THEN
    RAISE EXCEPTION 'case 1b: the deposit must open a remesa, got %', pg_temp.ops_t246(v_conv); END IF;

  -- 2. Negations in the same clause do not count.
  v_conv := pg_temp.conv_t246('02', ARRAY['no quiero combo, quiero una remesa', 'sin combo', 'no mandar comida, solo dinero']);
  IF cerebro_combo_en_curso(v_conv) THEN
    RAISE EXCEPTION 'case 2: negated mentions must not be a combo in progress'; END IF;

  -- 3. Orders still count (unchanged behaviour of 209).
  v_conv := pg_temp.conv_t246('03', ARRAY['hola', 'quiero mandar un combo']);
  IF NOT cerebro_combo_en_curso(v_conv) THEN RAISE EXCEPTION 'case 3a: "quiero mandar un combo" must be a combo'; END IF;
  v_conv := pg_temp.conv_t246('04', ARRAY['quiero 2 combos para mi mama']);
  IF NOT cerebro_combo_en_curso(v_conv) THEN RAISE EXCEPTION 'case 3b: "2 combos" must be a combo'; END IF;
  v_conv := pg_temp.conv_t246('05', ARRAY['quiero mandar comida para Cuba']);
  IF NOT cerebro_combo_en_curso(v_conv) THEN RAISE EXCEPTION 'case 3c: "mandar comida" must be a combo'; END IF;

  -- 4. A clause break ends the negation: "no, quiero un combo" is an order.
  v_conv := pg_temp.conv_t246('06', ARRAY['No, quiero un combo']);
  IF NOT cerebro_combo_en_curso(v_conv) THEN RAISE EXCEPTION 'case 4: "No, quiero un combo" must be a combo'; END IF;

  -- 5. A message boundary ends the negation: "no" then "quiero un combo" is an order.
  v_conv := pg_temp.conv_t246('07', ARRAY['no', 'quiero un combo']);
  IF NOT cerebro_combo_en_curso(v_conv) THEN RAISE EXCEPTION 'case 5: a "no" in the previous message must not cancel the order'; END IF;

  -- 6. One order among negated mentions still counts.
  v_conv := pg_temp.conv_t246('08', ARRAY['ni combo ni nada de eso', 'bueno si, mandame un combo']);
  IF NOT cerebro_combo_en_curso(v_conv) THEN RAISE EXCEPTION 'case 6: a later order must count'; END IF;

  -- 7. The window is unchanged: a combo text before the last closed operation does not count.
  v_conv := pg_temp.conv_t246('09', ARRAY['quiero mandar un combo']);
  SELECT account_id, contact_id INTO v_acc, v_ct FROM conversations WHERE id = v_conv;
  -- (cancelled, not completed: remittance_operations_completion_guard coerces an automation insert as completed to incident)
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, quoted_source_amount,
                                     source_currency, cancelled_at)
  VALUES (v_acc, v_conv, v_ct, 'cancelled', 'remesa', 10000, 'GYD', now());
  IF cerebro_combo_en_curso(v_conv) THEN RAISE EXCEPTION 'case 7: a text before the last closed operation must not count'; END IF;

  -- 8. cerebro_textos_cliente_recientes keeps its output (messages joined with a space, oldest first).
  v_conv := pg_temp.conv_t246('10', ARRAY['uno', 'dos tres']);
  IF cerebro_textos_cliente_recientes(v_conv) IS DISTINCT FROM 'uno dos tres' THEN
    RAISE EXCEPTION 'case 8: textos_cliente_recientes changed, got %', cerebro_textos_cliente_recientes(v_conv); END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
