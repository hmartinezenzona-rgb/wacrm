-- =====================================================================
-- Assertion for migration 196 (a manual close without beneficiary names its service, so the calculator prices it).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/remesa-closing-and-cash.md (A8). Production 2026-10-03: Yosvany 54c25086 (no beneficiary, no delivery
-- method) was closed manually and never reached the calculator. Owner: on such a close the panel asks the service with
-- icons; crm_cerrar_operacion_manual takes it as p_delivery_method and writes it in the same UPDATE as the status.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t196(p_tag text, p_method text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900196' || p_tag, 'test196' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 6200, p_method) RETURNING id INTO v_op;
  RETURN v_op;
END $$;

DO $$
DECLARE v_acc uuid; v_admin uuid; v_op uuid; v_ok boolean; v_r record;
BEGIN
  SELECT account_id INTO v_acc FROM conversations LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- 1. Yosvany's shape closed as CUP: the method is set and the calculator prices it.
  v_op := pg_temp.op_t196('01', NULL);
  PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'cuban_card');
  SELECT o.delivery_method AS m, e.service AS s, e.status AS st INTO v_r
    FROM remittance_operations o LEFT JOIN remittance_calculator_entries e ON e.operation_id = o.id AND e.status <> 'void'
   WHERE o.id = v_op;
  IF v_r.m IS DISTINCT FROM 'cuban_card' OR v_r.s IS DISTINCT FROM 'CUP' OR v_r.st IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'case 1: expected cuban_card / CUP completed, got % / % / %', v_r.m, v_r.s, v_r.st; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_manual_close'
                  AND after ->> 'delivery_method' = 'cuban_card') THEN
    RAISE EXCEPTION 'case 1: the chosen service must be audited'; END IF;

  -- 2. Cash works the same way.
  v_op := pg_temp.op_t196('02', NULL);
  PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'efectivo_usd');
  IF (SELECT service FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void') IS DISTINCT FROM 'EFECTIVO' THEN
    RAISE EXCEPTION 'case 2: a cash close must reach the calculator as EFECTIVO'; END IF;

  -- 3. An unknown service is refused.
  v_op := pg_temp.op_t196('03', NULL);
  v_ok := false;
  BEGIN PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'bitcoin'); EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: an unknown service must be refused with 22023'; END IF;

  -- 4. A remesa that already has a beneficiary keeps its own service: a chosen one is refused.
  v_op := pg_temp.op_t196('04', 'zelle');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Ana', 'ana@example.com', 1, 1, 'manual', 'vigente');
  v_ok := false;
  BEGIN PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'cuban_card'); EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4: choosing a service on a remesa with a beneficiary must be refused'; END IF;

  -- 5. Without a service the close still works as before (191 calls keep working).
  PERFORM crm_cerrar_operacion_manual(v_op);
  IF (SELECT status FROM remittance_operations WHERE id = v_op) <> 'completed' THEN
    RAISE EXCEPTION 'case 5: a close without a chosen service must still complete'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
