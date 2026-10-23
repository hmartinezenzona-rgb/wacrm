-- =====================================================================
-- Assertion for migration 179 (beneficiary data saved partial and in arrival order).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
--
-- The merge functions are PATCH, not replace: given fields overwrite, empty fields keep what is
-- saved; a different card never inherits the old card's phone; a different Zelle account never
-- inherits the old holder's name; reparto slots are matched by position. Owner rules D1 (arrival
-- order) and D2/D3 (ask when in doubt), 2026-10-01. Yeny (op 99a4065d) is case 7.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_vacia(p_tag text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
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
  v_conv uuid; v_r text; v_v text; v_n int;
BEGIN
  -- ---------------------------------------------------------------- parser
  SELECT count(*) INTO v_n FROM cerebro_parsear_beneficiarios(E'BENEFICIARIO\nTarjeta: -\nCelular: 53960583')
   WHERE tipo = 'cuban_card' AND tarjeta IS NULL AND celular = '53960583';
  IF v_n <> 1 THEN RAISE EXCEPTION 'P1: a phone without a card must parse as a partial row'; END IF;
  SELECT count(*) INTO v_n FROM cerebro_parsear_beneficiarios(E'BENEFICIARIO ZELLE\nNombre: Rodolfo valiente\nCuenta Zelle: -')
   WHERE tipo = 'zelle' AND nombre = 'Rodolfo valiente' AND cuenta_zelle IS NULL;
  IF v_n <> 1 THEN RAISE EXCEPTION 'P2: a Zelle holder without an account must parse as a partial row'; END IF;
  SELECT count(*) INTO v_n FROM cerebro_parsear_beneficiarios(
     E'REPARTO ENTRE VARIOS BENEFICIARIOS\n1) Tarjeta: 9238129972250411 | Celular: - | Recibe: 15000 CUP\n2) Tarjeta: 9248129970222428 | Celular: 53960583 | Recibe: -')
   WHERE tipo = 'multiple_distribution';
  IF v_n <> 2 THEN RAISE EXCEPTION 'P3: reparto lines with gaps must parse, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM cerebro_parsear_beneficiarios(E'BENEFICIARIO ZELLE\nNombre: -\nCuenta Zelle: -');
  IF v_n <> 0 THEN RAISE EXCEPTION 'P4: an empty block must not produce a row'; END IF;

  -- ------------------------------------------------------- single, Cuban card
  -- 1. card first, phone later (D1): one beneficiary, completed by the second call.
  v_conv := pg_temp.conv_vacia('01');
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', '9238 1299 7225 0411', '', 'x1');
  IF v_r !~* 'falta' OR pg_temp.vig(v_conv) <> 'cuban_card:_:9238129972250411:_:_:_' THEN
    RAISE EXCEPTION 'case 1a: card alone must be saved and say what is missing: % / %', v_r, pg_temp.vig(v_conv); END IF;
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', '', '+53 5 3960583', 'x2');
  IF pg_temp.vig(v_conv) <> 'cuban_card:_:9238129972250411:53960583:_:_' OR v_r ~* 'falta' THEN
    RAISE EXCEPTION 'case 1b: the phone must complete the saved card: % / %', v_r, pg_temp.vig(v_conv); END IF;

  -- 2. phone first, card later (D1).
  v_conv := pg_temp.conv_vacia('02');
  PERFORM cerebro_guardar_beneficiario(v_conv, '', '', '54363811', 'x1');
  IF pg_temp.vig(v_conv) <> 'cuban_card:_:_:54363811:_:_' THEN RAISE EXCEPTION 'case 2a: %', pg_temp.vig(v_conv); END IF;
  PERFORM cerebro_guardar_beneficiario(v_conv, '', '9227959879614050', '', 'x2');
  IF pg_temp.vig(v_conv) <> 'cuban_card:_:9227959879614050:54363811:_:_' THEN RAISE EXCEPTION 'case 2b: %', pg_temp.vig(v_conv); END IF;

  -- 3. a DIFFERENT card never inherits the old card's phone.
  PERFORM cerebro_guardar_beneficiario(v_conv, '', '9205129978614908', '', 'x3');
  IF pg_temp.vig(v_conv) <> 'cuban_card:_:9205129978614908:_:_:_' THEN RAISE EXCEPTION 'case 3: %', pg_temp.vig(v_conv); END IF;

  -- 4. a name correction keeps card and phone; the same data again changes nothing.
  v_conv := pg_temp.conv_vacia('04');
  PERFORM cerebro_guardar_beneficiario(v_conv, 'Roberto Diaz', '9227959879614050', '54363811', 'x1');
  PERFORM cerebro_guardar_beneficiario(v_conv, 'Oberto Diaz', '', '', 'x2');
  IF pg_temp.vig(v_conv) <> 'cuban_card:Oberto Diaz:9227959879614050:54363811:_:_' THEN RAISE EXCEPTION 'case 4a: %', pg_temp.vig(v_conv); END IF;
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, 'Oberto Diaz', '9227959879614050', '54363811', 'x3');
  IF v_r !~* 'sin cambios' THEN RAISE EXCEPTION 'case 4b: same data must be a no-op, got %', v_r; END IF;

  -- 5. invalid numbers are refused and nothing is written.
  v_conv := pg_temp.conv_vacia('05');
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', '92381299722504', '674 2713', 'x1');
  IF v_r !~* 'error' OR pg_temp.vig(v_conv) <> '' THEN RAISE EXCEPTION 'case 5: % / %', v_r, pg_temp.vig(v_conv); END IF;

  -- ------------------------------------------------------------------- Zelle
  -- 6. account first, holder later; a different account never inherits the holder; a name fix.
  v_conv := pg_temp.conv_vacia('06');
  SELECT accion INTO v_r FROM cerebro_guardar_zelle(v_conv, '', '+1 (786) 861-3281', 'x1');
  IF v_r !~* 'falta' OR pg_temp.vig(v_conv) <> 'zelle:_:_:_:7868613281:_' THEN RAISE EXCEPTION 'case 6a: % / %', v_r, pg_temp.vig(v_conv); END IF;
  PERFORM cerebro_guardar_zelle(v_conv, 'Liudis Aguilar Rojas', '', 'x2');
  IF pg_temp.vig(v_conv) <> 'zelle:Liudis Aguilar Rojas:_:_:7868613281:_' THEN RAISE EXCEPTION 'case 6b: %', pg_temp.vig(v_conv); END IF;
  PERFORM cerebro_guardar_zelle(v_conv, 'Liudis Aguilar Roja', '', 'x3');
  IF pg_temp.vig(v_conv) <> 'zelle:Liudis Aguilar Roja:_:_:7868613281:_' THEN RAISE EXCEPTION 'case 6c: %', pg_temp.vig(v_conv); END IF;
  -- (285) a different account with no position is refused (it used to replace); the correction names the position
  PERFORM cerebro_guardar_zelle(v_conv, '', 'rvalienter@outlook.com', 'x4', NULL, 'registrar_beneficiario_zelle', 1);
  IF pg_temp.vig(v_conv) <> 'zelle:_:_:_:rvalienter@outlook.com:_' THEN RAISE EXCEPTION 'case 6d: %', pg_temp.vig(v_conv); END IF;

  -- ----------------------------------------------------------------- reparto
  -- 7. Yeny: two cards, then "5 mil cada una" (15,000 CUP each), then the phone for both.
  v_conv := pg_temp.conv_vacia('07');
  SELECT accion INTO v_r FROM cerebro_guardar_reparto(v_conv, '9238129972250411', '', '', '9248129970222428', '53960583', '', '', '', '', 'x1');
  IF v_r !~* 'falta' OR pg_temp.vig(v_conv) <> 'multiple_distribution:_:9238129972250411:_:_:_ | multiple_distribution:_:9248129970222428:53960583:_:_' THEN
    RAISE EXCEPTION 'case 7a: % / %', v_r, pg_temp.vig(v_conv); END IF;
  PERFORM cerebro_guardar_reparto(v_conv, '', '', '15000 CUP', '', '', '15000 CUP', '', '', '', 'x2');
  IF pg_temp.vig(v_conv) <> 'multiple_distribution:_:9238129972250411:_:_:15000 CUP | multiple_distribution:_:9248129970222428:53960583:_:15000 CUP' THEN
    RAISE EXCEPTION 'case 7b: %', pg_temp.vig(v_conv); END IF;
  SELECT accion INTO v_r FROM cerebro_guardar_reparto(v_conv, '', '53960583', '', '', '', '', '', '', '', 'x3');
  IF v_r ~* 'falta' OR pg_temp.vig(v_conv) <> 'multiple_distribution:_:9238129972250411:53960583:_:15000 CUP | multiple_distribution:_:9248129970222428:53960583:_:15000 CUP' THEN
    RAISE EXCEPTION 'case 7c: % / %', v_r, pg_temp.vig(v_conv); END IF;

  -- 8. a change of one amount leaves the other person untouched; a new card in slot 2 resets its phone.
  PERFORM cerebro_guardar_reparto(v_conv, '', '', '20000 CUP', '', '', '', '', '', '', 'x4');
  IF pg_temp.vig(v_conv) <> 'multiple_distribution:_:9238129972250411:53960583:_:20000 CUP | multiple_distribution:_:9248129970222428:53960583:_:15000 CUP' THEN
    RAISE EXCEPTION 'case 8a: %', pg_temp.vig(v_conv); END IF;
  PERFORM cerebro_guardar_reparto(v_conv, '', '', '', '9224069992922522', '', '', '', '', '', 'x5');
  IF pg_temp.vig(v_conv) <> 'multiple_distribution:_:9238129972250411:53960583:_:20000 CUP | multiple_distribution:_:9224069992922522:_:_:_' THEN
    RAISE EXCEPTION 'case 8b: %', pg_temp.vig(v_conv); END IF;

  -- 9. a USD rail share keeps its rail; a bare USD amount with no rail is refused.
  v_conv := pg_temp.conv_vacia('09');
  PERFORM cerebro_guardar_reparto(v_conv, '9760039003648069', '52725088', '30 USD clasica', '9760039005544217', '59499176', '', '', '', '', 'x1');
  IF pg_temp.vig(v_conv) <> 'clasica:_:9760039003648069:52725088:_:30 USD | multiple_distribution:_:9760039005544217:59499176:_:_' THEN
    RAISE EXCEPTION 'case 9a: %', pg_temp.vig(v_conv); END IF;
  SELECT accion INTO v_r FROM cerebro_guardar_reparto(v_conv, '', '', '', '', '', '20 USD', '', '', '', 'x2');
  IF v_r !~* 'error' THEN RAISE EXCEPTION 'case 9b: a bare USD share must be refused, got %', v_r; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
