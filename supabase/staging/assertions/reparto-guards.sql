-- =====================================================================
-- Assertion for migration 184 (a single-beneficiary write never overwrites a vigente reparto).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
--
-- Staging live test 2 (2026-10-02): reparto saved with both cards, then gestionar_beneficiario
-- (card 1 + the phone) wrote a single cuban_card generation over it; card 2 and the amounts were lost.
-- With a vigente reparto, cerebro_guardar_beneficiario (bot tool and the auto node) now:
--   * a card that is in the reparto patches its slot;
--   * a lone phone fills the first slot without a phone (D1, arrival order);
--   * anything else is refused, nothing written, and the bot is told to use registrar_reparto_multiple.
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

CREATE OR REPLACE FUNCTION pg_temp.slots(p_conv uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(b.position || '=' || coalesce(b.card_number, '_') || ':' || coalesce(b.phone, '_') || ':'
                             || coalesce(b.amount::text, '_'), ' | ' ORDER BY b.position), '')
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled') AND b.status = 'vigente'
$$;

CREATE OR REPLACE FUNCTION pg_temp.gens(p_conv uuid) RETURNS int
LANGUAGE sql AS $$
  SELECT count(DISTINCT b.block_index)::int
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = p_conv
$$;

DO $$
DECLARE
  c1 constant text := '9238123432101987';
  c2 constant text := '9238123432101237';
  v_conv uuid; v_r text; v_g int;
BEGIN
  -- 1. Test 2 replayed: the reparto with both cards, then the single tool with card 1 + the phone.
  v_conv := pg_temp.conv_vacia('41');
  PERFORM cerebro_guardar_reparto(v_conv, c1, '', '', c2, '', '', '', '', '', 'x1');
  IF pg_temp.slots(v_conv) <> '1=' || c1 || ':_:_ | 2=' || c2 || ':_:_' THEN RAISE EXCEPTION 'case 1 setup: %', pg_temp.slots(v_conv); END IF;
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', c1, '53821203', 'x2');
  IF pg_temp.slots(v_conv) <> '1=' || c1 || ':53821203:_ | 2=' || c2 || ':_:_' THEN
    RAISE EXCEPTION 'case 1: the reparto was overwritten or not patched: % / %', v_r, pg_temp.slots(v_conv); END IF;
  IF v_r !~* 'reparto' THEN RAISE EXCEPTION 'case 1: the answer must speak of the reparto: %', v_r; END IF;

  -- 2. A lone phone fills the first slot without one (card 2 here).
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', '', '53821203', 'x3');
  IF pg_temp.slots(v_conv) <> '1=' || c1 || ':53821203:_ | 2=' || c2 || ':53821203:_' THEN
    RAISE EXCEPTION 'case 2: % / %', v_r, pg_temp.slots(v_conv); END IF;

  -- 3. A card that is not in the reparto: refused, nothing written.
  v_g := pg_temp.gens(v_conv);
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', '9205129978614908', '54363811', 'x4');
  IF pg_temp.gens(v_conv) <> v_g OR pg_temp.slots(v_conv) <> '1=' || c1 || ':53821203:_ | 2=' || c2 || ':53821203:_' THEN
    RAISE EXCEPTION 'case 3: a foreign card must not touch the reparto: % / %', v_r, pg_temp.slots(v_conv); END IF;
  IF v_r !~* 'registrar_reparto_multiple' THEN RAISE EXCEPTION 'case 3: the bot must be sent to the reparto tool: %', v_r; END IF;

  -- 4. Every slot has a phone, another lone phone: refused, nothing written.
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', '', '54363811', 'x5');
  IF pg_temp.gens(v_conv) <> v_g THEN RAISE EXCEPTION 'case 4: % / %', v_r, pg_temp.slots(v_conv); END IF;
  IF v_r !~* 'registrar_reparto_multiple' THEN RAISE EXCEPTION 'case 4: %', v_r; END IF;

  -- 5. The amounts survive a slot patch.
  v_conv := pg_temp.conv_vacia('42');
  PERFORM cerebro_guardar_reparto(v_conv, c1, '', '45000', c2, '', '30000', '', '', '', 'x1');
  PERFORM cerebro_guardar_beneficiario(v_conv, '', c2, '53821204', 'x2');
  IF pg_temp.slots(v_conv) <> '1=' || c1 || ':_:45000 | 2=' || c2 || ':53821204:30000' THEN
    RAISE EXCEPTION 'case 5: %', pg_temp.slots(v_conv); END IF;

  -- 6. The deterministic node (auto) takes the same path: burst phone only, accumulated card 1.
  v_conv := pg_temp.conv_vacia('43');
  PERFORM cerebro_guardar_reparto(v_conv, c1, '', '', c2, '', '', '', '', '', 'x1');
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario_auto(v_conv, '', '53821203', c1, '53821203', 'x2');
  IF pg_temp.slots(v_conv) <> '1=' || c1 || ':53821203:_ | 2=' || c2 || ':_:_' THEN
    RAISE EXCEPTION 'case 6: % / %', v_r, pg_temp.slots(v_conv); END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
