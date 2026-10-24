-- 295: calculator_unfed_operations lists an operation only when it truly lacks a live ledger line.
--
-- Fixture: two completed operations with no part at all (no recipients and no calculateable rail).
-- One of them already has a live entry -> must NOT be listed (was the 8dd1740c false positive).
-- The other has no entry -> must be listed, still as service_unresolved.
DO $$
DECLARE
  v_acc uuid; v_conv uuid; v_contact uuid;
  v_fed uuid := gen_random_uuid();
  v_unfed uuid := gen_random_uuid();
  v_fail text := '';
BEGIN
  SELECT c.account_id, c.id, c.contact_id INTO v_acc, v_conv, v_contact FROM conversations c LIMIT 1;

  -- A human actor, so 096's guard accepts an INSERT straight into completed.
  PERFORM set_config('wacrm.origin', 'admin', true);
  PERFORM set_config('wacrm.actor', 'prueba-295', true);

  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, source_country,
    source_currency, destination_currency, delivery_method, quoted_source_amount, completed_at)
  VALUES (v_fed,   v_acc, v_conv, v_contact, 'completed', 'remesa', 'GY', 'GYD', 'USD', NULL, 1000, now()),
         (v_unfed, v_acc, v_conv, v_contact, 'completed', 'remesa', 'GY', 'GYD', 'USD', NULL, 1000, now());

  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, service, amount,
    amount_currency, completed_at, facturado_gyd, invertido_gyd, retorno_gyd)
  VALUES (v_acc, 'completed_operation', 'completed', v_fed, current_date, 'CLASICA', 1000, 'GYD', now(), 1000, 900, 100);

  IF EXISTS (SELECT 1 FROM calculator_unfed_operations WHERE operation_id = v_fed) THEN
    v_fail := v_fail || ' 1:listed-with-live-entry';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM calculator_unfed_operations
                  WHERE operation_id = v_unfed AND unfed_reason = 'service_unresolved') THEN
    v_fail := v_fail || ' 2:missing-entry-not-listed';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
