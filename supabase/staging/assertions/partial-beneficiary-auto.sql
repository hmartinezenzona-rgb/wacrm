-- =====================================================================
-- Assertion for migration 180 (the deterministic nodes save partial data too).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
--
-- cerebro_guardar_beneficiario_auto(conv, burst card, burst phone, accumulated card, accumulated phone, exec)
-- cerebro_guardar_zelle_auto(conv, accumulated holder, accumulated account, exec)
--   * with an open remesa: what arrived in THIS burst is saved at once, partial, in arrival order;
--   * without one: a remesa is opened only with the complete pair (as before), so a lone Cuban
--     phone (a recarga, for instance) never opens a remesa.
-- =====================================================================
-- (2026-10-05) conv_vacia and vig are inlined from partial-beneficiary-tools.sql so this file runs alone; conv_vacia takes its user and
-- account from whatsapp_config + profiles instead of `FROM conversations LIMIT 1` (staging can have no conversation after a test reset).
CREATE OR REPLACE FUNCTION pg_temp.conv_vacia(p_tag text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900179' || p_tag, 'test179' || p_tag)
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.vig(p_conv uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(b.beneficiary_type || ':' || coalesce(b.name, '_') || ':' || coalesce(b.card_number, '_') || ':'
                             || coalesce(b.phone, '_') || ':' || coalesce(b.zelle_account, '_') || ':'
                             || coalesce(b.amount::text || ' ' || b.currency, '_'), ' | ' ORDER BY b.position), '')
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled') AND b.status = 'vigente'
$$;

DO $$
DECLARE
  v_conv uuid; v_r text; v_n int;
BEGIN
  -- 1. No open remesa, a lone phone: nothing is created.
  v_conv := pg_temp.conv_vacia('11');
  PERFORM cerebro_guardar_beneficiario_auto(v_conv, '', '54363811', '', '54363811', 'x1');
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 1: a lone phone must not open a remesa'; END IF;

  -- 2. No open remesa, the pair completed across bursts (accumulated): opened, as before.
  PERFORM cerebro_guardar_beneficiario_auto(v_conv, '9227959879614050', '', '9227959879614050', '54363811', 'x2');
  IF pg_temp.vig(v_conv) <> 'cuban_card:_:9227959879614050:54363811:_:_' THEN RAISE EXCEPTION 'case 2: %', pg_temp.vig(v_conv); END IF;

  -- 3. Open remesa, a NEW card alone in this burst (the accumulated phone is the old card's):
  --    the new card is saved without a phone (D1), never paired with the old phone.
  PERFORM cerebro_guardar_beneficiario_auto(v_conv, '9205129978614908', '', '9205129978614908', '54363811', 'x3');
  IF pg_temp.vig(v_conv) <> 'cuban_card:_:9205129978614908:_:_:_' THEN RAISE EXCEPTION 'case 3: %', pg_temp.vig(v_conv); END IF;

  -- 4. Open remesa, the phone arrives alone later: it completes the saved card.
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario_auto(v_conv, '', '53821208', '9205129978614908', '53821208', 'x4');
  IF pg_temp.vig(v_conv) <> 'cuban_card:_:9205129978614908:53821208:_:_' THEN RAISE EXCEPTION 'case 4: % / %', v_r, pg_temp.vig(v_conv); END IF;

  -- 5. Open remesa (from a Zelle account alone it is not opened; with holder + account it is).
  v_conv := pg_temp.conv_vacia('15');
  PERFORM cerebro_guardar_zelle_auto(v_conv, '', '+1 (786) 861-3281', 'x1');
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 5a: a lone Zelle account must not open a remesa'; END IF;
  PERFORM cerebro_guardar_zelle_auto(v_conv, 'Liudis Aguilar Rojas', '+1 (786) 861-3281', 'x2');
  IF pg_temp.vig(v_conv) <> 'zelle:Liudis Aguilar Rojas:_:_:7868613281:_' THEN RAISE EXCEPTION 'case 5b: %', pg_temp.vig(v_conv); END IF;

  -- 6. Open remesa, another account alone (Merge already dropped the old holder): saved without holder.
  PERFORM cerebro_guardar_zelle_auto(v_conv, '', 'rvalienter@outlook.com', 'x3');
  IF pg_temp.vig(v_conv) <> 'zelle:_:_:_:rvalienter@outlook.com:_' THEN RAISE EXCEPTION 'case 6: %', pg_temp.vig(v_conv); END IF;
  -- 7. ...and the holder later completes it.
  PERFORM cerebro_guardar_zelle_auto(v_conv, 'Rodolfo valiente', 'rvalienter@outlook.com', 'x4');
  IF pg_temp.vig(v_conv) <> 'zelle:Rodolfo valiente:_:_:rvalienter@outlook.com:_' THEN RAISE EXCEPTION 'case 7: %', pg_temp.vig(v_conv); END IF;

  -- 8. The bot tools keep their 179 behaviour (5 / 4 arguments, no operation given).
  v_conv := pg_temp.conv_vacia('18');
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', '9238129972250411', '', 'x1');
  IF v_r !~* 'falta' OR pg_temp.vig(v_conv) <> 'cuban_card:_:9238129972250411:_:_:_' THEN RAISE EXCEPTION 'case 8: % / %', v_r, pg_temp.vig(v_conv); END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
