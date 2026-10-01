-- =====================================================================
-- Assertion for migration 175 (a card reparto keeps the remesa's Zelle).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Case 1 replays Kenia's real note sequence (2026-09-29): Zelle block, two single-card blocks
-- written as the cards arrived, then the reparto between the two Clasica cards.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.deal_notas(p_tag text, p_notas text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_deal uuid; v_n text;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900175' || p_tag, 'test175' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, '78220927-0745-45a8-ba08-a1b33734dbf1', '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109', 'test175', 0, 'GYD', p_notas[1], 'open')
  RETURNING id INTO v_deal;
  FOR i IN 2 .. cardinality(p_notas) LOOP
    UPDATE deals SET notes = notes || E'\n---\n' || p_notas[i] WHERE id = v_deal;
  END LOOP;
  RETURN (SELECT id FROM remittance_operations WHERE deal_id = v_deal);
END $$;

DO $$
DECLARE v_op uuid; v_vig text;
  c_zelle CONSTANT text := 'BENEFICIARIO ZELLE' || chr(10) || 'Nombre: DTZ SOLUTION LLC' || chr(10) || 'Cuenta Zelle: 2294563108';
  c_card1 CONSTANT text := 'BENEFICIARIO ACTUALIZADO (auto) - reemplaza al anterior' || chr(10) || 'Tarjeta: 9760039005544217' || chr(10) || 'Celular: 52725088';
  c_card2 CONSTANT text := 'BENEFICIARIO ACTUALIZADO (auto) - reemplaza al anterior' || chr(10) || 'Tarjeta: 9760039003648069' || chr(10) || 'Celular: 59499176';
  c_reparto CONSTANT text := 'REPARTO ACTUALIZADO ENTRE VARIOS BENEFICIARIOS - reemplaza lo anterior' || chr(10) ||
                             '1) Tarjeta: 9760039003648069 | Celular: 52725088 | Recibe: 30 USD Clasica' || chr(10) ||
                             '2) Tarjeta: 9760039005544217 | Celular: 59499176 | Recibe: 20 USD Clasica';
BEGIN
  -- 1. Kenia: Zelle, single cards, then the reparto -> Zelle + both Clasica cards are vigente.
  v_op := pg_temp.deal_notas('01', ARRAY[c_zelle, c_card1, c_card2, c_reparto]);
  SELECT string_agg(beneficiary_type || coalesce(':' || zelle_account, ':' || card_number), ',' ORDER BY beneficiary_type, card_number)
    INTO v_vig FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_vig IS DISTINCT FROM 'clasica:9760039003648069,clasica:9760039005544217,zelle:2294563108' THEN
    RAISE EXCEPTION 'case 1: expected the Zelle and both Clasica cards vigente, got %', v_vig;
  END IF;

  -- 2. Zelle then ONE card (no reparto): the customer changed rail, the card replaces the Zelle as before.
  v_op := pg_temp.deal_notas('02', ARRAY[c_zelle, c_card1]);
  SELECT string_agg(beneficiary_type, ',') INTO v_vig FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_vig IS DISTINCT FROM 'cuban_card' THEN RAISE EXCEPTION 'case 2: a single card must still replace the Zelle, got %', v_vig; END IF;

  -- 3. A reparto with no Zelle in the remesa is unchanged: only its cards are vigente.
  v_op := pg_temp.deal_notas('03', ARRAY[c_card1, c_reparto]);
  SELECT count(*)::text INTO v_vig FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_vig <> '2' THEN RAISE EXCEPTION 'case 3: expected the 2 reparto cards, got %', v_vig; END IF;

  -- 4. Two Zelle blocks (the customer corrected the account): only the LATEST one comes back.
  v_op := pg_temp.deal_notas('04', ARRAY[c_zelle,
    'BENEFICIARIO ZELLE ACTUALIZADO - reemplaza al anterior' || chr(10) || 'Nombre: RF Consulting Business' || chr(10) || 'Cuenta Zelle: 6562419849', c_reparto]);
  SELECT string_agg(zelle_account, ',') INTO v_vig FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'zelle';
  IF v_vig IS DISTINCT FROM '6562419849' THEN RAISE EXCEPTION 'case 4: only the latest Zelle must stay, got %', v_vig; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
