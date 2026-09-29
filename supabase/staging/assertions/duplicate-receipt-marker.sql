-- duplicate-receipt-marker.sql — self-reverting assertion for
-- 146_duplicate_receipt_marker.sql
--
-- Production feedback 2026-09-29, A1: a receipt whose image hash was already
-- registered is dropped silently and leaves no trace. The user chose a SILENT
-- marker: count the resend on the original hash row, notify nobody.
--
-- cerebro_marcar_reenvio_comprobante(hash, wamid) returns true when it counted
-- a NEW resend, false otherwise (unknown hash, the original message itself, or
-- a webhook replay of a resend already counted).
--
-- RED (before 146): the function does not exist.
-- GREEN (after 146): all cases pass.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. All data is synthetic.

SAVEPOINT duplicate_receipt_marker;

DO $$
DECLARE
  v_hash      CONSTANT text := 'test-hash-duplicate-receipt-marker';
  v_deals_0   bigint;
  v_msgs_0    bigint;
  v_audit_0   bigint;
  v_res       boolean;
  v_n         integer;
  v_wamid     text;
  v_at        timestamptz;
  v_fail      integer := 0;
BEGIN
  INSERT INTO comprobantes_hashes (hash_imagen, cliente_whatsapp, comp_id, whatsapp_message_id)
  VALUES (v_hash, '5920000000', 'COMP-test-marker', 'wamid.ORIGINAL');

  SELECT count(*) INTO v_deals_0 FROM deals;
  SELECT count(*) INTO v_msgs_0 FROM messages;
  SELECT count(*) INTO v_audit_0 FROM remittance_admin_audit;

  -- case 1: a resend under a new wamid is counted
  v_res := cerebro_marcar_reenvio_comprobante(v_hash, 'wamid.RESEND1');
  SELECT reenvios, ultimo_reenvio_wamid, ultimo_reenvio_at INTO v_n, v_wamid, v_at
    FROM comprobantes_hashes WHERE hash_imagen = v_hash;
  IF v_res IS DISTINCT FROM true OR v_n <> 1 OR v_wamid <> 'wamid.RESEND1' OR v_at IS NULL THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [case 1] resend not counted: res=%, reenvios=%, wamid=%, at=%', v_res, v_n, v_wamid, v_at;
  ELSE RAISE NOTICE 'PASS [case 1] a resend under a new wamid is counted'; END IF;

  -- case 2: replay of the same resend does not double count
  v_res := cerebro_marcar_reenvio_comprobante(v_hash, 'wamid.RESEND1');
  SELECT reenvios INTO v_n FROM comprobantes_hashes WHERE hash_imagen = v_hash;
  IF v_res IS DISTINCT FROM false OR v_n <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [case 2] replay double counted: res=%, reenvios=%', v_res, v_n;
  ELSE RAISE NOTICE 'PASS [case 2] a replay of a counted resend is ignored'; END IF;

  -- case 3: the original message itself is not a resend
  v_res := cerebro_marcar_reenvio_comprobante(v_hash, 'wamid.ORIGINAL');
  SELECT reenvios INTO v_n FROM comprobantes_hashes WHERE hash_imagen = v_hash;
  IF v_res IS DISTINCT FROM false OR v_n <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [case 3] original counted as resend: res=%, reenvios=%', v_res, v_n;
  ELSE RAISE NOTICE 'PASS [case 3] the original message is not counted'; END IF;

  -- case 4: a second, different resend is counted
  v_res := cerebro_marcar_reenvio_comprobante(v_hash, 'wamid.RESEND2');
  SELECT reenvios INTO v_n FROM comprobantes_hashes WHERE hash_imagen = v_hash;
  IF v_res IS DISTINCT FROM true OR v_n <> 2 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [case 4] second resend not counted: res=%, reenvios=%', v_res, v_n;
  ELSE RAISE NOTICE 'PASS [case 4] a second resend is counted (2 total)'; END IF;

  -- case 5: unknown hash creates nothing and returns false
  v_res := cerebro_marcar_reenvio_comprobante('test-hash-unknown', 'wamid.X');
  IF v_res IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM comprobantes_hashes WHERE hash_imagen = 'test-hash-unknown') THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [case 5] unknown hash: res=%', v_res;
  ELSE RAISE NOTICE 'PASS [case 5] an unknown hash is ignored and not created'; END IF;

  -- case 6: a resend without a wamid is still counted
  v_res := cerebro_marcar_reenvio_comprobante(v_hash, NULL);
  SELECT reenvios INTO v_n FROM comprobantes_hashes WHERE hash_imagen = v_hash;
  IF v_res IS DISTINCT FROM true OR v_n <> 3 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [case 6] null wamid resend: res=%, reenvios=%', v_res, v_n;
  ELSE RAISE NOTICE 'PASS [case 6] a resend without wamid is counted'; END IF;

  -- case 7: silent — no deal, message or audit row was created
  IF (SELECT count(*) FROM deals) <> v_deals_0
     OR (SELECT count(*) FROM messages) <> v_msgs_0
     OR (SELECT count(*) FROM remittance_admin_audit) <> v_audit_0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [case 7] marking a resend created deals, messages or audit rows';
  ELSE RAISE NOTICE 'PASS [case 7] marking is silent: no deal, message or audit row'; END IF;

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'duplicate-receipt-marker: % expectation(s) FAILED — see WARNINGs above', v_fail;
  END IF;
  RAISE NOTICE 'duplicate-receipt-marker: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT duplicate_receipt_marker;
