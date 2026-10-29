-- =====================================================================
-- Assertion for migration 352 (a forced verification counts as funded for delivery). Self-reverting.
-- Synthetic fixtures only (contacts '5993520xx', fake accounts @example.com).
-- Cases:
--   a. unfunded op, no forced verification -> refused with the funding message (still)
--   b. the same op with a human_forced_verification audit -> delivered (RED before 352)
--   c. forced but recipients do not add up / delivery proofs missing / no source amount -> still refused
--   d. forced then a later human_deposit_verification, or a later return to deposit_verification -> refused
--   e. mixed group: one member forced -> refused; both forced -> both deliver
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_op2 uuid;
  v_err text; v_status text; v_fail int := 0;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  CREATE FUNCTION pg_temp.f_op(p_n int, p_rail text, p_src numeric, p_dest numeric, p_cur text) RETURNS uuid
  LANGUAGE plpgsql AS $f$
  DECLARE v_ct uuid; v_cv uuid; v_o uuid; v_u uuid; v_a uuid;
  BEGIN
    SELECT p.user_id, p.account_id INTO v_u, v_a FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
     ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
    INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_u, v_a, '5993520' || lpad(p_n::text, 3, '0'), 'PRUEBA 352 ' || p_n) RETURNING id INTO v_ct;
    INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_u, v_a, v_ct) RETURNING id INTO v_cv;
    v_o := cerebro_crear_operacion(v_cv);
    UPDATE remittance_operations
       SET service_type = 'remesa', delivery_method = p_rail, status = 'ready_to_transfer',
           quoted_source_amount = p_src, quoted_destination_amount = p_dest, destination_currency = p_cur
     WHERE id = v_o;
    RETURN v_o;
  END $f$;

  CREATE FUNCTION pg_temp.f_ben(p_op uuid, p_pos int, p_amt numeric) RETURNS void
  LANGUAGE sql AS $f$
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
    VALUES (p_op, 'zelle', 'PRUEBA 352 B' || p_pos, 'b352' || p_pos || '@example.com', p_amt, 'USD', p_pos, 'vigente', 'manual');
  $f$;

  CREATE FUNCTION pg_temp.f_audit(p_acc uuid, p_op uuid, p_action text, p_status text) RETURNS void
  LANGUAGE sql AS $f$
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (p_acc, 'remittance_operations', p_op, 'status', p_action, 'prueba 352', 'prueba',
            jsonb_build_object('status', 'deposit_verification'), jsonb_build_object('status', p_status));
  $f$;

  CREATE FUNCTION pg_temp.f_try(p_op uuid, p_mode text) RETURNS text
  LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM crm_entregar_operacion(p_op, jsonb_build_object('mode', p_mode), true, NULL);
    RETURN 'DELIVERED';
  EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
  END $f$;

  -- a + b
  v_op := pg_temp.f_op(1, 'zelle', 26000, 100, 'USD'); PERFORM pg_temp.f_ben(v_op, 1, 100);
  v_err := pg_temp.f_try(v_op, 'skip_proof');
  IF v_err NOT LIKE '%0 GYD of verified funding but needs 26000 GYD%' THEN v_fail := v_fail + 1; RAISE WARNING 'a: got %', v_err; END IF;
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_forced_verification', 'ready_to_transfer');
  v_err := pg_temp.f_try(v_op, 'skip_proof');
  IF v_err <> 'DELIVERED' THEN v_fail := v_fail + 1; RAISE WARNING 'b: got %', v_err; END IF;
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op;
  IF v_status <> 'completed' THEN v_fail := v_fail + 1; RAISE WARNING 'b: status %', v_status; END IF;

  -- c1 recipients do not add up
  v_op := pg_temp.f_op(2, 'zelle', 26000, 100, 'USD'); PERFORM pg_temp.f_ben(v_op, 1, 60);
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_forced_verification', 'ready_to_transfer');
  v_err := pg_temp.f_try(v_op, 'skip_proof');
  IF v_err NOT LIKE '%add up to 60%' THEN v_fail := v_fail + 1; RAISE WARNING 'c1: got %', v_err; END IF;
  -- c2 delivery proofs missing (2 beneficiaries, proof_sent)
  v_op := pg_temp.f_op(3, 'zelle', 26000, 100, 'USD'); PERFORM pg_temp.f_ben(v_op, 1, 60); PERFORM pg_temp.f_ben(v_op, 2, 40);
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_forced_verification', 'ready_to_transfer');
  v_err := pg_temp.f_try(v_op, 'proof_sent');
  IF v_err NOT LIKE '%every beneficiary needs its delivery proof%' THEN v_fail := v_fail + 1; RAISE WARNING 'c2: got %', v_err; END IF;
  -- c3 no source amount
  v_op := pg_temp.f_op(4, 'zelle', 0, 100, 'USD'); PERFORM pg_temp.f_ben(v_op, 1, 100);
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_forced_verification', 'ready_to_transfer');
  v_err := pg_temp.f_try(v_op, 'skip_proof');
  IF v_err NOT LIKE '%no source amount%' THEN v_fail := v_fail + 1; RAISE WARNING 'c3: got %', v_err; END IF;

  -- d1 superseded by a real deposit verification; d2 sent back to deposit_verification; d3 forward move stays valid
  v_op := pg_temp.f_op(5, 'zelle', 26000, 100, 'USD'); PERFORM pg_temp.f_ben(v_op, 1, 100);
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_forced_verification', 'ready_to_transfer');
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_deposit_verification', 'ready_to_transfer');
  v_err := pg_temp.f_try(v_op, 'skip_proof');
  IF v_err NOT LIKE '%verified funding%' THEN v_fail := v_fail + 1; RAISE WARNING 'd1: got %', v_err; END IF;
  v_op := pg_temp.f_op(6, 'zelle', 26000, 100, 'USD'); PERFORM pg_temp.f_ben(v_op, 1, 100);
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_forced_verification', 'ready_to_transfer');
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_correction', 'deposit_verification');
  v_err := pg_temp.f_try(v_op, 'skip_proof');
  IF v_err NOT LIKE '%verified funding%' THEN v_fail := v_fail + 1; RAISE WARNING 'd2: got %', v_err; END IF;
  v_op := pg_temp.f_op(7, 'zelle', 26000, 100, 'USD'); PERFORM pg_temp.f_ben(v_op, 1, 100);
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_forced_verification', 'ready_to_transfer');
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_correction', 'ready_to_transfer');
  v_err := pg_temp.f_try(v_op, 'skip_proof');
  IF v_err <> 'DELIVERED' THEN v_fail := v_fail + 1; RAISE WARNING 'd3: got %', v_err; END IF;

  -- e mixed group
  v_op := pg_temp.f_op(8, 'zelle', 10000, 40, 'USD'); PERFORM pg_temp.f_ben(v_op, 1, 40);
  v_op2 := pg_temp.f_op(9, 'zelle', 13000, 50, 'USD'); PERFORM pg_temp.f_ben(v_op2, 1, 50);
  UPDATE remittance_operations SET mixed_group_id = v_op WHERE id IN (v_op, v_op2);
  PERFORM pg_temp.f_audit(v_acc, v_op, 'human_forced_verification', 'ready_to_transfer');
  v_err := pg_temp.f_try(v_op, 'skip_proof');
  IF v_err NOT LIKE '%verified funding%' THEN v_fail := v_fail + 1; RAISE WARNING 'e1: got %', v_err; END IF;
  PERFORM pg_temp.f_audit(v_acc, v_op2, 'human_forced_verification', 'ready_to_transfer');
  v_err := pg_temp.f_try(v_op, 'skip_proof');
  IF v_err <> 'DELIVERED' THEN v_fail := v_fail + 1; RAISE WARNING 'e2 first: got %', v_err; END IF;
  v_err := pg_temp.f_try(v_op2, 'skip_proof');
  IF v_err <> 'DELIVERED' THEN v_fail := v_fail + 1; RAISE WARNING 'e2 second: got %', v_err; END IF;

  IF v_fail > 0 THEN RAISE EXCEPTION 'FAILED % expectation(s)', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
