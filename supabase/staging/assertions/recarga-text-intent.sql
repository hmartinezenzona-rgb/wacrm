\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 392 (cerebro_guardar_beneficiario_auto: a typed recarga with Cuban mobiles is registered as a recarga).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. The staging script strips BEGIN/ROLLBACK/\set and wraps it.
-- Production incident 2026-11-24 (capture mode, bot paused): the customer wrote "recarga" plus two 8-digit Cuban mobiles. The auto-writer
-- saved ONE cuban_card recipient with the first mobile on an open remesa and lost the second; no recharge number was registered.
-- Rule asserted (the 7th argument is the written text of the batch; NULL = old callers, nothing new applies):
--   * the batch asks for a recarga (cerebro_texto_pide_recarga, negations honoured), carries Cuban mobiles and NO card, a promo runs
--     and no recarga is open: the recarga is declared and ALL mobiles are registered through crm_registrar_numeros_recarga on
--     (a) the single open unfunded remesa whose recipients are phone-only (converted by _cambiar_servicio_core, no second operation),
--     (b) a new recarga operation when nothing is open and the bot is not paused; when paused and nothing is open only the
--         declaration is kept (pending data, no operation opened);
--   * more than one distinct mobile and no card never writes a cuban_card recipient from a bare mobile.
--   A  paused + open phone-only remesa + "recarga" + 2 mobiles -> same op becomes recarga with both numbers, no cuban_card
--   B  not paused, nothing open, "recarga" + 2 mobiles           -> one recarga op, two numbers, declared
--   C  paused, nothing open                                       -> no operation, declaration kept
--   D  negated "no quiero recarga" + 2 mobiles, open remesa       -> untouched
--   E  no recarga word + 2 mobiles, open remesa                   -> untouched (never a cuban_card from a bare mobile)
--   F  remesa that carries a real card + "recarga" + 2 mobiles    -> not converted, nothing written
--   G  open recarga + "recarga" + 2 mobiles                       -> both numbers on it (268 path unchanged)
--   H  6-argument call (old n8n node)                             -> still works
--   I  one mobile + "recarga", nothing open, not paused           -> recarga op with that number
--   J  "recarga" + a card in the batch                            -> not a recarga
--   K  "recarga" + 2 mobiles with NO promo                        -> nothing converted, nothing written
-- =====================================================================

CREATE FUNCTION pg_temp.t392_conv(p_n int, p_paused boolean) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990392' || lpad(p_n::text, 4, '0'), 'T392 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id, ai_autoreply_disabled)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc, p_paused) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

-- An open unfunded remesa; p_kind: 'phone' = one phone-only cuban_card recipient (the notes_parse shape of the incident),
-- 'card' = a recipient with a real card, 'none' = no recipient.
CREATE FUNCTION pg_temp.t392_remesa(p_c record, p_kind text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id, status, service_type,
                                     quoted_source_amount, source_currency, delivery_method)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, NULL, 'collecting_information', 'remesa', 0, 'GYD', 'cuban_card')
  RETURNING id INTO v_op;
  IF p_kind = 'phone' THEN
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
    VALUES (v_op, 'cuban_card', '55599180', 1, 1, 'notes_parse', 'vigente');
  ELSIF p_kind = 'card' THEN
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
    VALUES (v_op, 'cuban_card', '9225959870001234', '55599180', 1, 1, 'notes_parse', 'vigente');
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t392_recarga_op(p_c record) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id, status, service_type,
                                     quoted_source_amount, source_currency)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, NULL, 'collecting_information', 'recarga', 0, 'GYD')
  RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

-- The call under test with 7 arguments, as the fixed n8n node makes it; errors come back as text so a missing function counts as one
-- failed expectation instead of aborting the file.
CREATE FUNCTION pg_temp.t392_auto7(p_conv uuid, p_tarjeta text, p_celular text, p_texto text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_r text;
BEGIN
  EXECUTE 'SELECT accion FROM cerebro_guardar_beneficiario_auto($1, $2, $3, $4, $5, $6, $7)'
     INTO v_r USING p_conv, p_tarjeta, p_celular, p_tarjeta, p_celular, 't392', p_texto;
  RETURN coalesce(v_r, '');
EXCEPTION WHEN OTHERS THEN
  RETURN 'ERR: ' || SQLERRM;
END $f$;

CREATE FUNCTION pg_temp.t392_auto6(p_conv uuid, p_celular text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_r text;
BEGIN
  EXECUTE 'SELECT accion FROM cerebro_guardar_beneficiario_auto($1, $2, $3, $4, $5, $6)'
     INTO v_r USING p_conv, '', p_celular, '', p_celular, 't392';
  RETURN coalesce(v_r, '');
EXCEPTION WHEN OTHERS THEN
  RETURN 'ERR: ' || SQLERRM;
END $f$;

CREATE FUNCTION pg_temp.t392_ops(p_conv uuid) RETURNS text LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(o.service_type || '/' || o.status, ';' ORDER BY o.created_at, o.id), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$f$;

CREATE FUNCTION pg_temp.t392_recips(p_conv uuid) RETURNS text LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(b.beneficiary_type || ':' || coalesce(b.phone, '-') || CASE WHEN b.card_number IS NOT NULL THEN ':card' ELSE '' END,
                             ',' ORDER BY b.position, b.id), '')
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = p_conv AND b.status = 'vigente';
$f$;

CREATE FUNCTION pg_temp.t392_declared(p_conv uuid) RETURNS text LANGUAGE sql AS $f$
  SELECT coalesce((SELECT d.servicio FROM cerebro_servicio_declarado d WHERE d.conversation_id = p_conv), '');
$f$;

CREATE FUNCTION pg_temp.t392_ex(p_ok boolean, p_label text, p_got text) RETURNS int LANGUAGE plpgsql AS $f$
BEGIN
  IF coalesce(p_ok, false) THEN RETURN 0; END IF;
  RAISE NOTICE 'FAILED expectation %: got [%]', p_label, p_got;
  RETURN 1;
END $f$;

DO $$
DECLARE
  c record; v_op uuid; v_r text; v_fail int := 0;
  c_dos constant text := 'hola quiero una recarga para 55599180 y 53330001';
BEGIN
  -- A recarga needs a live promo: this one runs for every case but K.
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-392'), 'confirmada');

  -- ---- A: the incident replay (capture mode: paused, open remesa with the first mobile as a cuban_card) --------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(1, true);
  v_op := pg_temp.t392_remesa(c, 'phone');
  v_r := pg_temp.t392_auto7(c.conv, '', '55599180', c_dos);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = 'recarga/collecting_information', 'A1 one recarga op, no second op', pg_temp.t392_ops(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_recips(c.conv) = 'recarga:55599180,recarga:53330001', 'A2 both numbers as recarga', pg_temp.t392_recips(c.conv));
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_declared(c.conv) = 'recarga', 'A3 recarga declared', pg_temp.t392_declared(c.conv));
  v_fail := v_fail + pg_temp.t392_ex((SELECT id FROM remittance_operations WHERE conversation_id = c.conv) = v_op, 'A4 same operation reused', '');

  -- ---- B: not paused, nothing open ----------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(2, false);
  v_r := pg_temp.t392_auto7(c.conv, '', '55599180', c_dos);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = 'recarga/collecting_information', 'B1 one recarga op opened', pg_temp.t392_ops(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_recips(c.conv) = 'recarga:55599180,recarga:53330001', 'B2 both numbers', pg_temp.t392_recips(c.conv));
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_declared(c.conv) = 'recarga', 'B3 declared', pg_temp.t392_declared(c.conv));

  -- ---- C: paused, nothing open: no operation, the declaration is the pending data --------------------------------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(3, true);
  v_r := pg_temp.t392_auto7(c.conv, '', '55599180', c_dos);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = '', 'C1 no operation opened while paused', pg_temp.t392_ops(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_recips(c.conv) = '', 'C2 no recipient written', pg_temp.t392_recips(c.conv));
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_declared(c.conv) = 'recarga', 'C3 declaration kept', pg_temp.t392_declared(c.conv));

  -- ---- D: negated mention ------------------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(4, false);
  v_op := pg_temp.t392_remesa(c, 'phone');
  v_r := pg_temp.t392_auto7(c.conv, '', '55599180', 'no quiero recarga, son para 55599180 y 53330001');
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = 'remesa/collecting_information', 'D1 stays a remesa', pg_temp.t392_ops(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_recips(c.conv) = 'cuban_card:55599180', 'D2 recipients untouched', pg_temp.t392_recips(c.conv));
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_declared(c.conv) = '', 'D3 nothing declared', pg_temp.t392_declared(c.conv));

  -- ---- E: two mobiles, no recarga word ---------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(5, false);
  v_op := pg_temp.t392_remesa(c, 'none');
  v_r := pg_temp.t392_auto7(c.conv, '', '55599180', 'estos son los numeros 55599180 y 53330001');
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_recips(c.conv) = '', 'E1 no cuban_card from a bare mobile', pg_temp.t392_recips(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = 'remesa/collecting_information', 'E2 stays a remesa', pg_temp.t392_ops(c.conv));

  -- ---- F: the remesa already carries a real card ------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(6, false);
  v_op := pg_temp.t392_remesa(c, 'card');
  v_r := pg_temp.t392_auto7(c.conv, '', '55599180', c_dos);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = 'remesa/collecting_information', 'F1 not converted', pg_temp.t392_ops(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_recips(c.conv) = 'cuban_card:55599180:card', 'F2 recipients untouched', pg_temp.t392_recips(c.conv));

  -- ---- G: a recarga is already open (268 path) --------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(7, false);
  v_op := pg_temp.t392_recarga_op(c);
  v_r := pg_temp.t392_auto7(c.conv, '', '55599180', c_dos);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_recips(c.conv) = 'recarga:55599180,recarga:53330001', 'G1 both numbers on the open recarga', pg_temp.t392_recips(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = 'recarga/collecting_information', 'G2 still one op', pg_temp.t392_ops(c.conv));

  -- ---- H: the old 6-argument call keeps working --------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(8, false);
  v_op := pg_temp.t392_remesa(c, 'none');
  v_r := pg_temp.t392_auto6(c.conv, '55599180');
  v_fail := v_fail + pg_temp.t392_ex(v_r NOT LIKE 'ERR:%', 'H1 6-argument call', v_r);

  -- ---- I: one mobile + recarga -------------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(9, false);
  v_r := pg_temp.t392_auto7(c.conv, '', '55599180', 'una recarga para 55599180');
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = 'recarga/collecting_information', 'I1 recarga op', pg_temp.t392_ops(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_recips(c.conv) = 'recarga:55599180', 'I2 the number', pg_temp.t392_recips(c.conv));

  -- ---- J: a card in the batch is not a recarga -----------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t392_conv(10, false);
  v_op := pg_temp.t392_remesa(c, 'none');
  v_r := pg_temp.t392_auto7(c.conv, '9225959870005678', '55599180', 'recarga? no, a esta tarjeta 9225959870005678 y el celular 55599180');
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = 'remesa/collecting_information', 'J1 stays a remesa', pg_temp.t392_ops(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_declared(c.conv) = '', 'J2 nothing declared', pg_temp.t392_declared(c.conv));

  -- ---- K: no promo (this case closes every promo of the transaction) --------------------------------------------------------------
  UPDATE promo_etecsa SET vigente_hasta = (now() AT TIME ZONE 'America/Guyana')::date - 2,
                          vigente_desde = (now() AT TIME ZONE 'America/Guyana')::date - 5;
  SELECT * INTO c FROM pg_temp.t392_conv(11, false);
  v_op := pg_temp.t392_remesa(c, 'phone');
  v_r := pg_temp.t392_auto7(c.conv, '', '55599180', c_dos);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_ops(c.conv) = 'remesa/collecting_information', 'K1 not converted without a promo', pg_temp.t392_ops(c.conv) || ' / ' || v_r);
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_recips(c.conv) = 'cuban_card:55599180', 'K2 no bare cuban_card added, none retired', pg_temp.t392_recips(c.conv));
  v_fail := v_fail + pg_temp.t392_ex(pg_temp.t392_declared(c.conv) = '', 'K3 nothing declared without a promo', pg_temp.t392_declared(c.conv));

  IF v_fail > 0 THEN
    RAISE EXCEPTION '% expectation(s) failed', v_fail;
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
