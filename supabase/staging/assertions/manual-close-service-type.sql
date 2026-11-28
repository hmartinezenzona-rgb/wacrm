\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 249 (a manual close names the service the way the panel's service change does).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Production 2026-10-19 (operation 02a2d634): a Zelle deposit misfiled as a combo. Closing it manually with 'zelle' would
-- have left service_type 'combo' (only recarga/combo/visa/saldo set it), so the calculator kept billing a COMBO; the
-- operator chose 'saldo' and it became a mobile balance with a stale combo cost. Rule asserted, the one
-- _cambiar_servicio_core uses: the chosen service IS the operation's service (a remesa rail -> 'remesa' with that delivery
-- method), the combo cost survives only on a combo, and a service change is audited. odd/tasks/combo-negated-mention.md.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t248(p_tag text, p_service text, p_combo_cost numeric) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900248' || p_tag, 'test248' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency,
                                     quoted_source_amount, combo_costo_gyd)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', p_service, 'GYD', 28600, p_combo_cost) RETURNING id INTO v_op;
  RETURN v_op;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.state_t248(p_op uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT o.status || '/' || o.service_type || '/' || coalesce(o.delivery_method, '-') || '/' || coalesce(o.combo_costo_gyd::int::text, '-')
    FROM remittance_operations o WHERE o.id = p_op;
$$;

DO $$
DECLARE v_acc uuid; v_admin uuid; v_op uuid; v_a jsonb;
BEGIN
  SELECT w.account_id INTO v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- 1. The production case: a misfiled combo closed as Zelle becomes a Zelle remesa, without the combo cost.
  v_op := pg_temp.op_t248('01', 'combo', 28600);
  PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'zelle');
  IF pg_temp.state_t248(v_op) <> 'completed/remesa/zelle/-' THEN
    RAISE EXCEPTION 'case 1: a combo closed as zelle must be a zelle remesa without combo cost, got %', pg_temp.state_t248(v_op); END IF;
  IF (SELECT service FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void') = 'COMBO' THEN
    RAISE EXCEPTION 'case 1: the calculator must not bill a COMBO'; END IF;
  SELECT after INTO v_a FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_manual_close';
  IF v_a ->> 'service_type' IS DISTINCT FROM 'remesa' OR v_a ->> 'service_type_before' IS DISTINCT FROM 'combo' THEN
    RAISE EXCEPTION 'case 1: the service change must be audited, got %', v_a; END IF;

  -- 2. A recharge closed as CUP becomes a CUP remesa.
  v_op := pg_temp.op_t248('02', 'recarga', NULL);
  PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'cuban_card');
  IF pg_temp.state_t248(v_op) <> 'completed/remesa/cuban_card/-' THEN
    RAISE EXCEPTION 'case 2: a recarga closed as cuban_card must be a CUP remesa, got %', pg_temp.state_t248(v_op); END IF;

  -- 3. Unchanged (223): a remesa closed as saldo is a saldo, with no delivery method.
  v_op := pg_temp.op_t248('03', 'remesa', NULL);
  PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'saldo');
  IF pg_temp.state_t248(v_op) <> 'completed/saldo/-/-' THEN
    RAISE EXCEPTION 'case 3: a remesa closed as saldo must be a saldo, got %', pg_temp.state_t248(v_op); END IF;

  -- 4. A combo closed as combo keeps its cost, and nothing is audited as a service change.
  v_op := pg_temp.op_t248('04', 'combo', 18000);
  PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'combo');
  IF pg_temp.state_t248(v_op) <> 'completed/combo/-/18000' THEN
    RAISE EXCEPTION 'case 4: a combo closed as combo must keep its cost, got %', pg_temp.state_t248(v_op); END IF;
  SELECT after INTO v_a FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_manual_close';
  IF v_a ? 'service_type_before' THEN RAISE EXCEPTION 'case 4: no service change to audit, got %', v_a; END IF;

  -- 5. A combo closed as saldo (what the operator did) is a saldo without the stale combo cost.
  v_op := pg_temp.op_t248('05', 'combo', 28600);
  PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'saldo');
  IF pg_temp.state_t248(v_op) <> 'completed/saldo/-/-' THEN
    RAISE EXCEPTION 'case 5: a combo closed as saldo must drop the combo cost, got %', pg_temp.state_t248(v_op); END IF;

  -- 6. Without a chosen service nothing about the service changes (191).
  v_op := pg_temp.op_t248('06', 'combo', 20000);
  PERFORM crm_cerrar_operacion_manual(v_op);
  IF pg_temp.state_t248(v_op) <> 'completed/combo/-/20000' THEN
    RAISE EXCEPTION 'case 6: a close without a service must keep the combo, got %', pg_temp.state_t248(v_op); END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
