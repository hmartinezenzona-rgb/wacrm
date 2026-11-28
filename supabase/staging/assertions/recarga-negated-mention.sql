\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 248 (a negated "recarga" is not a recharge order; one negation rule for combo and recarga).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- cerebro_recarga_en_curso (202/211) has the bare-word shape 247 removed from the combo rule: "no quiero recarga" was a
-- recharge order. Rule asserted: per message, a mention negated in the same clause does not count; the Zelle guard and
-- the promo condition are unchanged. odd/tasks/combo-negated-mention.md.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t247(p_tag text, p_texts text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_i int := 0; v_t text;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;  -- not from conversations: staging can have none after a reset
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900247' || p_tag, 'test247' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  FOREACH v_t IN ARRAY p_texts LOOP
    v_i := v_i + 1;
    INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
    VALUES (v_conv, 'customer', 'text', v_t, now() - make_interval(mins => 30 - v_i));
  END LOOP;
  RETURN v_conv;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.ops_t247(p_conv uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(o.service_type || '/' || o.status || '/' || o.quoted_source_amount::int, ';' ORDER BY o.created_at, o.service_type), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$$;

DO $$
DECLARE
  v_conv uuid;
  c_verif constant uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
BEGIN
  -- (211) A typed recharge needs a promo running: these cases run with one.
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-248'), 'confirmada');

  -- 1. A negated recharge is not an order, and the deposit that follows opens a remesa.
  v_conv := pg_temp.conv_t247('01', ARRAY['no quiero recarga, quiero mandar dinero a una tarjeta']);
  IF cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 1: "no quiero recarga" must not be a recharge in progress'; END IF;
  PERFORM cerebro_registrar_deposito(v_conv, 20000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t247(v_conv) <> 'remesa/deposit_verification/20000' THEN
    RAISE EXCEPTION 'case 1b: the deposit must open a remesa, got %', pg_temp.ops_t247(v_conv); END IF;

  -- 2. Other negations, inflected forms included.
  v_conv := pg_temp.conv_t247('02', ARRAY['ni recargas ni nada de eso', 'no voy a recargarle']);
  IF cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 2: negated mentions must not be a recharge in progress'; END IF;

  -- 3. Orders still count (unchanged behaviour of 202/211).
  v_conv := pg_temp.conv_t247('03', ARRAY['quiero una recarga para mi mama']);
  IF NOT cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 3a: "quiero una recarga" must be a recharge'; END IF;
  v_conv := pg_temp.conv_t247('04', ARRAY['hay promo de etecsa?']);
  IF NOT cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 3b: "etecsa" must be a recharge'; END IF;

  -- 4. A clause or message boundary ends the negation.
  v_conv := pg_temp.conv_t247('05', ARRAY['No, quiero una recarga']);
  IF NOT cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 4a: "No, quiero una recarga" must be a recharge'; END IF;
  v_conv := pg_temp.conv_t247('06', ARRAY['no', 'quiero una recarga']);
  IF NOT cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 4b: a "no" in the previous message must not cancel the order'; END IF;

  -- 5. The Zelle guard is unchanged: Zelle typed anywhere in the window is never a recharge.
  v_conv := pg_temp.conv_t247('07', ARRAY['quiero una recarga', 'mejor por zelle']);
  IF cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 5: Zelle typed must still block the recharge'; END IF;

  -- 6. The combo rule keeps 247's behaviour on the shared negation rule.
  IF cerebro_texto_pide_combo('⚠️NO ESCRIBIR NADA DE CUBA REMESAS NI COMBO ECT ⚠️') THEN RAISE EXCEPTION 'case 6a: negated combo'; END IF;
  IF NOT cerebro_texto_pide_combo('quiero mandar un combo') THEN RAISE EXCEPTION 'case 6b: combo order'; END IF;
  IF NOT cerebro_texto_pide_combo('No, quiero mandar comida') THEN RAISE EXCEPTION 'case 6c: comida order after a clause break'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
