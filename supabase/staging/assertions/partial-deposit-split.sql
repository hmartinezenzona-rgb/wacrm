\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 280 (repartir_envio with a PARTIAL deposit: the bot applies the parts the verified deposit covers,
-- the DB checks assigned <= verified deposit and each part's minimum, uncovered parts stay pending with their data).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Synthetic fixtures only: contacts 'PRUEBA parcial N', phones 5990280xxxx, fake CLABE / card. Deposits are VERIFIED (MMG row + cruce).
-- Cases (number = label in the failure message):
--   1  plan zelle 39000 / efectivo 29000 / cup 15000, verified deposit 71,200: apply "zelle 39000, efectivo 29000" -> partial: a group
--      of two with those amounts, the CUP part stays an empty operation WITH its card, the plan keeps only the CUP part (15000), the
--      answer says partial, 3,200 left unassigned and the pending part; the deposit is untouched
--   2  the next verified deposit (15,000) attaches to the pending CUP operation (no new operation, card kept)
--   3  parts above the verified deposit (44,000 deposited, 68,000 sent): facts, nothing changed, no group
--   4  a part below its minimum (cup 3000 with 80,000 verified): refused naming the part, nothing changed
--   5  one covered part while others wait ("zelle 39000" with 39,000 verified): applied, no group, plan keeps the other two; the
--      later deposit of exactly their total (44,000) splits them by itself
--   6  one part and nothing pending: refused as before
--   7  no plan at all, deposit 71,200 on a clasica card, parts clasica 40000 + recarga 10000: partial, 21,200 unassigned
-- =====================================================================
--   7  the plan goes when the conversation's last operation closes
--   8  ACL: the plan table and the helpers are service_role only
-- =====================================================================

CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990280' || lpad(p_n::text, 4, '0'), 'PRUEBA parcial ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.p_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

-- "rail/amount" of every open operation, sorted
CREATE FUNCTION pg_temp.p_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(cerebro_riel_op(o.id) || '/' || coalesce(o.quoted_source_amount::int::text, '-'), ';' ORDER BY cerebro_riel_op(o.id)), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.p_plan(p_conv uuid) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT cerebro_resolver_servicio(p_conv) -> 'reparto_planeado'; $f$;

-- a deposit that is verified: MMG row in the ledger + registrar + cruce (same as split-deposit-minimums)
CREATE FUNCTION pg_temp.p_verifica(p_conv uuid, p_monto numeric, p_ref text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en) VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test280', now());
  SELECT r.deal_id INTO v_id FROM pg_temp.p_registra(p_conv, p_monto, p_ref) r;
  PERFORM cerebro_cruzar_depositos(v_id, ARRAY[p_ref], ARRAY[p_monto],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', '3cf01654-cd27-47c1-ac92-62abf5435751');
END $f$;

CREATE FUNCTION pg_temp.p_grupos(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT count(DISTINCT mixed_group_id)::text FROM remittance_operations WHERE conversation_id = p_conv AND status <> 'cancelled' AND mixed_group_id IS NOT NULL;
$f$;

CREATE FUNCTION pg_temp.p_benef(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(cerebro_riel_op(o.id) || ':' || (SELECT count(*) FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'),
                  ';' ORDER BY cerebro_riel_op(o.id)), '') FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

CREATE FUNCTION pg_temp.p_datos(p_conv uuid, p_n int) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM cerebro_guardar_beneficiario(p_conv, '', '9999000000000008', '53821203', 'p280a' || p_n);
  PERFORM crm_registrar_datos_entrega_efectivo(p_conv, '53821204', 'Calle 10 numero 5, Bayamo', NULL, 'Rosa Gomez');
  PERFORM cerebro_guardar_zelle(p_conv, 'Ana Perez', 'ana' || p_n || '@example.com', 'p280z' || p_n);
END $f$;

DO $$
DECLARE
  c record; v_a text; v_p jsonb;
BEGIN
  -- 1 partial: two parts applied, the third pending with its data
  SELECT * INTO c FROM pg_temp.p_conv(1);
  PERFORM cerebro_repartir_envio(c.conv, 'zelle 39000, efectivo 29000, cup 15000', 'q1a');
  PERFORM pg_temp.p_datos(c.conv, 1);
  PERFORM pg_temp.p_verifica(c.conv, 71200, '90409990028001');
  v_a := cerebro_repartir_envio(c.conv, 'zelle 39000, efectivo 29000', 'q1b');
  PERFORM pg_temp.p_eq('1 partial text', (v_a LIKE 'Reparto parcial hecho%' AND v_a LIKE '%zelle 39,000 GYD%' AND v_a LIKE '%efectivo USD 29,000 GYD%'
                                           AND v_a LIKE '%sobran 3,200 GYD%' AND v_a LIKE '%tarjeta CUP 15,000 GYD%')::text, 'true');
  PERFORM pg_temp.p_eq('1 amounts', pg_temp.p_ops(c.conv), 'cuban_card/0;efectivo_usd/29000;zelle/39000');
  PERFORM pg_temp.p_eq('1 one group of two', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL) || '/' || pg_temp.p_grupos(c.conv), '2/1');
  PERFORM pg_temp.p_eq('1 recipients kept (pending one too)', pg_temp.p_benef(c.conv), 'cuban_card:1;efectivo_usd:1;zelle:1');
  PERFORM pg_temp.p_eq('1 plan keeps the pending part', (SELECT total_gyd::text || ':' || jsonb_array_length(partes) FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '15000:1');
  PERFORM pg_temp.p_eq('1 deposit untouched', (SELECT trim_scale(sum(monto))::text FROM depositos_mmg WHERE trans_id = '90409990028001' AND anulado_en IS NULL AND consumido_en IS NOT NULL), '71200');
  PERFORM pg_temp.p_eq('1 outcome logged', (SELECT outcome FROM tool_execution_log WHERE tool_name = 'repartir_envio' AND conversation_id = c.conv AND execution_id = 'q1b'), 'parcial');

  -- 2 the next verified deposit attaches to the pending operation
  PERFORM pg_temp.p_verifica(c.conv, 15000, '90409990028002');
  PERFORM pg_temp.p_eq('2 no new operation', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND status <> 'cancelled'), '3');
  PERFORM pg_temp.p_eq('2 pending operation got the deposit', (SELECT quoted_source_amount::text FROM remittance_operations o WHERE o.conversation_id = c.conv AND cerebro_riel_op(o.id) = 'cuban_card'), '15000');
  PERFORM pg_temp.p_eq('2 recipients still there', pg_temp.p_benef(c.conv), 'cuban_card:1;efectivo_usd:1;zelle:1');

  -- 3 parts above the verified deposit
  SELECT * INTO c FROM pg_temp.p_conv(2);
  PERFORM cerebro_repartir_envio(c.conv, 'zelle 39000, efectivo 29000, cup 15000', 'q3a');
  PERFORM pg_temp.p_datos(c.conv, 3);
  PERFORM pg_temp.p_verifica(c.conv, 44000, '90409990028003');
  v_a := cerebro_repartir_envio(c.conv, 'zelle 39000, efectivo 29000', 'q3b');
  PERFORM pg_temp.p_eq('3 facts', (v_a LIKE 'REPARTO NO APLICADO%' AND v_a LIKE '%68,000%' AND v_a LIKE '%44,000%')::text, 'true');
  PERFORM pg_temp.p_eq('3 nothing changed', pg_temp.p_grupos(c.conv) || '/' || (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '0/83000');

  -- 4 a part below its minimum
  SELECT * INTO c FROM pg_temp.p_conv(3);
  PERFORM cerebro_repartir_envio(c.conv, 'zelle 39000, efectivo 29000, cup 15000', 'q4a');
  PERFORM pg_temp.p_datos(c.conv, 4);
  PERFORM pg_temp.p_verifica(c.conv, 80000, '90409990028004');
  v_a := cerebro_repartir_envio(c.conv, 'zelle 70000, cup 3000', 'q4b');
  PERFORM pg_temp.p_eq('4 refused naming the part', (v_a LIKE 'REPARTO NO APLICADO%' AND v_a LIKE '%tarjeta CUP%' AND v_a LIKE '%3,000%' AND v_a LIKE '%5,000%')::text, 'true');
  PERFORM pg_temp.p_eq('4 nothing changed', pg_temp.p_grupos(c.conv) || '/' || (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '0/83000');

  -- 5 a single covered part while the others wait
  SELECT * INTO c FROM pg_temp.p_conv(4);
  PERFORM cerebro_repartir_envio(c.conv, 'zelle 39000, efectivo 29000, cup 15000', 'q5a');
  PERFORM pg_temp.p_datos(c.conv, 5);
  PERFORM pg_temp.p_verifica(c.conv, 39000, '90409990028005');
  v_a := cerebro_repartir_envio(c.conv, 'zelle 39000', 'q5b');
  PERFORM pg_temp.p_eq('5 partial text', (v_a LIKE 'Reparto parcial hecho%' AND v_a LIKE '%zelle 39,000 GYD%' AND v_a LIKE '%efectivo USD 29,000 GYD%' AND v_a LIKE '%tarjeta CUP 15,000 GYD%')::text, 'true');
  PERFORM pg_temp.p_eq('5 no group', pg_temp.p_grupos(c.conv), '0');
  PERFORM pg_temp.p_eq('5 plan keeps two', (SELECT total_gyd::text || ':' || jsonb_array_length(partes) FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '44000:2');
  PERFORM pg_temp.p_verifica(c.conv, 44000, '90409990028006');
  PERFORM pg_temp.p_eq('5 the pending two split by themselves', pg_temp.p_ops(c.conv), 'cuban_card/15000;efectivo_usd/29000;zelle/39000');
  PERFORM pg_temp.p_eq('5 plan gone', (SELECT count(*)::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '0');

  -- 6 one part, nothing pending
  SELECT * INTO c FROM pg_temp.p_conv(5);
  PERFORM cerebro_guardar_beneficiario(c.conv, 'Luisa Gonzalez', '9999000000000008', '53821203', 'q6a');
  PERFORM pg_temp.p_verifica(c.conv, 30000, '90409990028007');
  v_a := cerebro_repartir_envio(c.conv, 'clasica 20000', 'q6b');
  PERFORM pg_temp.p_eq('6 refused', (v_a LIKE 'No se pudo repartir%' OR v_a LIKE 'REPARTO NO APLICADO%')::text, 'true');
  PERFORM pg_temp.p_eq('6 nothing changed', pg_temp.p_ops(c.conv), 'cuban_card/30000');

  -- 7 no plan, partial on a deposit with a card
  SELECT * INTO c FROM pg_temp.p_conv(6);
  PERFORM cerebro_guardar_beneficiario(c.conv, 'Luisa Gonzalez', '9999000000000008', '53821203', 'q7a');
  PERFORM cerebro_aplicar_servicio(c.conv, 'clasica', NULL, 'agent:test', 'q7');
  PERFORM pg_temp.p_verifica(c.conv, 71200, '90409990028008');
  v_a := cerebro_repartir_envio(c.conv, 'clasica 40000, recarga 10000', 'q7b');
  PERFORM pg_temp.p_eq('7 partial', (v_a LIKE 'Reparto parcial hecho%' AND v_a LIKE '%sobran 21,200 GYD%' AND v_a LIKE '%No quedan partes pendientes%')::text, 'true');
  PERFORM pg_temp.p_eq('7 amounts', pg_temp.p_ops(c.conv), 'clasica/40000;recarga/10000');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
