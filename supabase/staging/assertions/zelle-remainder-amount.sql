-- =====================================================================
-- Assertion for migration 176 (a kept Zelle gets the remainder of the remesa).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Rates read from crm_tasa_vigente, so the expected amounts follow them.
-- =====================================================================
-- (2026-10-05) The two helpers below are inlined from reparto-keeps-zelle.sql (deal_notas, rebuilt deal-free) and requested-amount-target.sql (bot_dice) so this file runs alone.
-- (2026-10-05) Helper rebuilt: a deal no longer creates the operation (161/172/183), so the operation comes from cerebro_crear_operacion and
-- the deal is linked to it; the notes sync (cerebro_sync_beneficiarios, 175's subject, still driven by deals.notes) is re-fired once the
-- operation exists. User and account come from whatsapp_config + profiles, not from an existing conversation.
CREATE OR REPLACE FUNCTION pg_temp.deal_notas(p_tag text, p_notas text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_deal uuid; v_op uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900175' || p_tag, 'test175' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, '78220927-0745-45a8-ba08-a1b33734dbf1', '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109', 'test175', 0, 'GYD', p_notas[1], 'open')
  RETURNING id INTO v_deal;
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;
  FOR i IN 2 .. cardinality(p_notas) LOOP
    UPDATE deals SET notes = notes || E'\n---\n' || p_notas[i] WHERE id = v_deal;
  END LOOP;
  RETURN v_op;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.bot_dice(p_conv uuid, p_texto text) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, ai_generated)
  VALUES (p_conv, 'agent', 'text', p_texto, true);
$$;

DO $$
DECLARE v_op uuid; v_z numeric; v_usd numeric := crm_tasa_vigente('usd'); v_cup numeric := crm_tasa_vigente('gyd');
  c_zelle CONSTANT text := 'BENEFICIARIO ZELLE' || chr(10) || 'Nombre: DTZ SOLUTION LLC' || chr(10) || 'Cuenta Zelle: 2294563108';
  c_reparto CONSTANT text := 'REPARTO ACTUALIZADO ENTRE VARIOS BENEFICIARIOS - reemplaza lo anterior' || chr(10) ||
                             '1) Tarjeta: 9760039003648069 | Celular: 52725088 | Recibe: 30 USD Clasica' || chr(10) ||
                             '2) Tarjeta: 9760039005544217 | Celular: 59499176 | Recibe: 20 USD Clasica';
BEGIN
  -- 1. Kenia: 39,000 GYD deposited, 30 + 20 USD Clasica -> the Zelle gets the rest (150 - 50 = 100 at 260).
  v_op := pg_temp.deal_notas('11', ARRAY[c_zelle, c_reparto]);
  UPDATE remittance_operations SET quoted_source_amount = 39000, status = 'deposit_verification' WHERE id = v_op;
  SELECT amount INTO v_z FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'zelle';
  IF v_z IS DISTINCT FROM floor(39000 / v_usd) - 50 THEN RAISE EXCEPTION 'case 1: Zelle should get %, got %', floor(39000 / v_usd) - 50, v_z; END IF;

  -- 2. Before the deposit, the bot's quote is the total.
  v_op := pg_temp.deal_notas('12', ARRAY[c_zelle]);
  PERFORM pg_temp.bot_dice((SELECT conversation_id FROM remittance_operations WHERE id = v_op), 'Para *150 USD* necesita depositar *39,000 GYD*.');
  UPDATE deals SET notes = notes || E'\n---\n' || c_reparto WHERE id = (SELECT deal_id FROM remittance_operations WHERE id = v_op);
  SELECT amount INTO v_z FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'zelle';
  IF v_z IS DISTINCT FROM floor(39000 / v_usd) - 50 THEN RAISE EXCEPTION 'case 2: Zelle from the quote should be %, got %', floor(39000 / v_usd) - 50, v_z; END IF;

  -- 3. A CUP card in the reparto is discounted at the CUP rate: 26,000 - 15,000 CUP (5,000 GYD) = 21,000 -> floor(21000/usd).
  v_op := pg_temp.deal_notas('13', ARRAY[c_zelle, 'REPARTO ENTRE VARIOS BENEFICIARIOS' || chr(10) ||
    '1) Tarjeta: 9227959879614050 | Celular: 54363811 | Recibe: 15000 CUP' || chr(10) ||
    '2) Tarjeta: 9760039005544217 | Celular: 59499176 | Recibe: 20 USD Clasica']);
  UPDATE remittance_operations SET quoted_source_amount = 26000, status = 'deposit_verification' WHERE id = v_op;
  SELECT amount INTO v_z FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'zelle';
  IF v_z IS DISTINCT FROM floor((26000 - 15000 / v_cup) / v_usd) - 20 THEN
    RAISE EXCEPTION 'case 3: expected %, got %', floor((26000 - 15000 / v_cup) / v_usd) - 20, v_z;
  END IF;

  -- 4. The cards already take everything: no Zelle amount is invented.
  v_op := pg_temp.deal_notas('14', ARRAY[c_zelle, c_reparto]);
  UPDATE remittance_operations SET quoted_source_amount = 13000, status = 'deposit_verification' WHERE id = v_op;
  SELECT amount INTO v_z FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'zelle';
  IF v_z IS NOT NULL THEN RAISE EXCEPTION 'case 4: nothing left, the Zelle must stay empty, got %', v_z; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
