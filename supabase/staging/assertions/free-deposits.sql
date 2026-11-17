-- =====================================================================
-- Assertion for migration 380 (crm_depositos_sin_dueno: the MMG ledger deposits nobody owns, for the panel's "link a deposit" picker).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA380', phones 5990380xxxx, deposits with trans_id 'PRUEBA380-...'.
-- A deposit is free when it has no operation, was not consumed, annulled or discarded. The picker shows the newest first (45 days, 40 rows)
-- and links one with the panel's existing verify, so this function only reads. Cases:
--   1  a free deposit appears with trans_id, amount, currency, received_at and the holder; the newest comes first
--   2  not listed: one linked to an operation, consumed, annulled, discarded, or older than 45 days
--   3  at most 40 rows
--   4  refused: an unknown operation, a user who is not a member
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_r jsonb; v_ids text[]; v_n int; v_ok boolean; i int;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990380001', 'PRUEBA380 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'deposit_verification', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_op;

  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en) VALUES
    ('PRUEBA380-LIBRE-1', 13000, 'GYD', 'PRUEBA Pagador Uno', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '1 hour'),
    ('PRUEBA380-LIBRE-2', 5000, 'GYD', 'PRUEBA Pagador Dos', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '2 hours'),
    ('PRUEBA380-VIEJO', 7000, 'GYD', NULL, 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '60 days');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, operation_id) VALUES ('PRUEBA380-CON-OP', 9000, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '3 hours', v_op);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en) VALUES ('PRUEBA380-CONSUMIDO', 9100, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '3 hours', now());
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, anulado_en, motivo_anulacion) VALUES ('PRUEBA380-ANULADO', 9200, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '3 hours', now(), 'prueba');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, descartado_en, descartado_motivo) VALUES ('PRUEBA380-DESCARTADO', 9300, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '3 hours', now(), 'prueba');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1 listed, newest first
  v_r := crm_depositos_sin_dueno(v_op);
  SELECT coalesce(array_agg(e ->> 'trans_id' ORDER BY ord), ARRAY[]::text[]) INTO v_ids FROM jsonb_array_elements(v_r) WITH ORDINALITY AS t(e, ord) WHERE e ->> 'trans_id' LIKE 'PRUEBA380-%';
  IF v_ids IS DISTINCT FROM ARRAY['PRUEBA380-LIBRE-1', 'PRUEBA380-LIBRE-2'] THEN RAISE EXCEPTION 'case 1/2: only the two free ones, newest first, got %', v_ids; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r) e WHERE e ->> 'trans_id' = 'PRUEBA380-LIBRE-1' AND (e ->> 'amount')::numeric = 13000 AND e ->> 'currency' = 'GYD'
                  AND e ->> 'holder' = 'PRUEBA Pagador Uno' AND e ->> 'received_at' IS NOT NULL) THEN
    RAISE EXCEPTION 'case 1: the item must carry trans_id, amount, currency, received_at and holder: %', v_r; END IF;

  -- 3 at most 40
  FOR i IN 1..45 LOOP
    INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en) VALUES ('PRUEBA380-MUCHOS-' || i, 1000 + i, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '10 minutes' - (i || ' seconds')::interval);
  END LOOP;
  v_n := jsonb_array_length(crm_depositos_sin_dueno(v_op));
  IF v_n <> 40 THEN RAISE EXCEPTION 'case 3: at most 40 rows, got %', v_n; END IF;

  -- 4 refusals
  v_ok := false;
  BEGIN PERFORM crm_depositos_sin_dueno(gen_random_uuid());
  EXCEPTION WHEN SQLSTATE 'P0002' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4a: an unknown operation must be refused'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN PERFORM crm_depositos_sin_dueno(v_op);
  EXCEPTION WHEN SQLSTATE '42501' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4b: a user who is not a member must be refused'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
