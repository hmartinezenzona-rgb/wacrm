-- =====================================================================
-- Assertion for migration 197 (a misread receipt reference still finds its MMG email). Self-reverting: one DO block
-- that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production (references start with 99: never real).
--
-- odd/tasks/vision-document-catalog.md (V0). Production, 28-sep..2-oct: of 50 receipts read, 3 references were misread
-- (one digit 5->3; two digits swapped 78<->87; one badly read photo of a monitor) and each needed a forced verification
-- by hand; their real MMG emails stayed unconsumed. The approximate match demanded the same first 5 and last 4 digits
-- (missed the swap) and the late re-cross only took EXACT references (missed an email ingested seconds after the photo).
-- cerebro_ref_parecida: same length +-1 and at most 2 edits (a swap of neighbours counts as 1). Still required: same
-- amount, unconsumed, inside the window, ONE candidate; an approximate match keeps alerting the admin to check it.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t197(p_tag text, p_ref text, p_monto numeric) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900197' || p_tag, 'test197' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, updated_at)
  VALUES (v_acc, v_conv, v_ct, 'deposit_verification', 'remesa', 'GYD', p_monto, now() - interval '5 minutes') RETURNING id INTO v_op;
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, amount, currency, receipt_status, reference, source)
  VALUES (v_op, v_conv, p_monto, 'GYD', 'EXITOSA', p_ref, 'bot');
  RETURN v_op;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.mail_t197(p_trans text, p_monto numeric) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en) VALUES (p_trans, p_monto, 'GYD', 'test197', now() - interval '2 minutes');
$$;

DO $$
DECLARE
  c_ok CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  c_esperado CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_op uuid; v_r record; v_case record;
BEGIN
  -- 1. The similarity rule.
  FOR v_case IN SELECT * FROM (VALUES
      ('99401883558716', '99401883358716', true,  'one digit changed'),
      ('99402124278772', '99402124277872', true,  'two neighbours swapped'),
      ('99402124278770', '99402124277872', true,  'swap + one change'),
      ('9940212427787',  '99402124277872', true,  'one digit missing'),
      ('99027229638060', '99402122268980', false, 'badly read'),
      ('99401883000016', '99401883358716', false, 'three digits changed'))
    AS t(leida, real, esperado, label)
  LOOP
    IF cerebro_ref_parecida(v_case.leida, v_case.real) IS DISTINCT FROM v_case.esperado THEN
      RAISE EXCEPTION 'case 1 "%": % vs % must be %', v_case.label, v_case.leida, v_case.real, v_case.esperado; END IF;
  END LOOP;

  -- 2. At receipt time: two neighbours swapped at the END (the old prefix/suffix rule missed it) -> verified, consumed.
  PERFORM pg_temp.mail_t197('99402124277872', 60000);
  v_op := pg_temp.op_t197('01', '99402124278772', 60000);
  SELECT * INTO v_r FROM cerebro_cruzar_deposito(v_op, '99402124278772', 60000, c_ok, c_esperado, c_esperado, false);
  IF v_r.resultado <> 'verificado' OR v_r.metodo <> 'aproximado' OR v_r.trans_id <> '99402124277872' THEN
    RAISE EXCEPTION 'case 2: expected verificado / aproximado / 99402124277872, got % / % / %', v_r.resultado, v_r.metodo, v_r.trans_id; END IF;
  IF (SELECT operation_id FROM depositos_mmg WHERE trans_id = '99402124277872') IS DISTINCT FROM v_op THEN
    RAISE EXCEPTION 'case 2: the real email must be consumed by this operation'; END IF;

  -- 3. Two similar candidates of the same amount: ambiguous, nothing consumed.
  PERFORM pg_temp.mail_t197('99501883358716', 10000);
  PERFORM pg_temp.mail_t197('99501883358719', 10000);
  v_op := pg_temp.op_t197('02', '99501883558716', 10000);
  SELECT * INTO v_r FROM cerebro_cruzar_deposito(v_op, '99501883558716', 10000, c_ok, c_esperado, c_esperado, false);
  IF v_r.resultado = 'verificado' THEN RAISE EXCEPTION 'case 3: two candidates must not verify'; END IF;

  -- 4. The email arrives AFTER the photo: the late re-cross (cerebro_recruzar_depositos_tardios, every few minutes, on
  --    operations untouched for 90 s) runs cerebro_cruzar_pendientes per operation; that one now pairs a reading one
  --    digit off. (The 90 s age guard cannot be faked here — the touch trigger rewrites updated_at and
  --    session_replication_role is not allowed — so the re-cross's own filter is checked on its source.)
  v_op := pg_temp.op_t197('03', '99601883558716', 12000);  -- not 10000: case 3's emails are similar too
  PERFORM pg_temp.mail_t197('99601883358716', 12000);
  SELECT * INTO v_r FROM cerebro_cruzar_pendientes(v_op);
  IF v_r.resultado IS DISTINCT FROM 'verificado'
     OR (SELECT status FROM remittance_operations WHERE id = v_op) IS DISTINCT FROM 'ready_to_transfer'
     OR (SELECT operation_id FROM depositos_mmg WHERE trans_id = '99601883358716') IS DISTINCT FROM v_op THEN
    RAISE EXCEPTION 'case 4: the pending re-cross must verify with the similar reference, got % / status %',
      v_r.resultado, (SELECT status FROM remittance_operations WHERE id = v_op); END IF;
  IF (SELECT prosrc FROM pg_proc WHERE proname = 'cerebro_recruzar_depositos_tardios') NOT LIKE '%cerebro_ref_parecida%' THEN
    RAISE EXCEPTION 'case 4: the late re-cross filter must also take similar references'; END IF;

  -- 5. An exact reference still works as before.
  PERFORM pg_temp.mail_t197('99701883358716', 5000);
  v_op := pg_temp.op_t197('04', '99701883358716', 5000);
  SELECT * INTO v_r FROM cerebro_cruzar_deposito(v_op, '99701883358716', 5000, c_ok, c_esperado, c_esperado, false);
  IF v_r.resultado <> 'verificado' OR v_r.metodo <> 'exacto' THEN
    RAISE EXCEPTION 'case 5: an exact reference must verify exactly, got % / %', v_r.resultado, v_r.metodo; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
