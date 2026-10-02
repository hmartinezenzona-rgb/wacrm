-- =====================================================================
-- Assertion for migration 186 (a beneficiary change touches its operation, so Realtime fires).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
--
-- odd/tasks/panel-realtime-beneficiaries.md. The operations panel listens to remittance_operations
-- (3b5f5dc). A bot beneficiary write (a phone added to a saved card, a reparto slot) did not UPDATE
-- the operation row, so no Realtime event reached the panel. The count of UPDATEs on
-- remittance_operations in this transaction (pg_stat_xact_user_tables.n_tup_upd) is the witness:
-- every UPDATE is a WAL change that Realtime publishes.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t186(p_tag text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900186' || p_tag, 'test186' || p_tag)
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.op_updates() RETURNS bigint
LANGUAGE sql AS $$
  SELECT coalesce(sum(n_tup_upd), 0) FROM pg_stat_xact_user_tables WHERE relname = 'remittance_operations'
$$;

DO $$
DECLARE
  c1 constant text := '9238123432101987';
  c2 constant text := '9238123432101237';
  v_conv uuid; v_op uuid; v_before bigint; v_after bigint;
  v_snap jsonb; v_snap2 jsonb; v_audit int; v_notif int;
BEGIN
  -- 1. A card saved by the bot, then the phone alone: the phone write must touch the operation.
  v_conv := pg_temp.conv_t186('01');
  PERFORM cerebro_guardar_beneficiario(v_conv, '', c1, '', 'x1');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;
  IF v_op IS NULL THEN RAISE EXCEPTION 'case 1 setup: the card did not open an operation'; END IF;
  SELECT to_jsonb(o) - 'updated_at' - 'version' INTO v_snap FROM remittance_operations o WHERE o.id = v_op;
  SELECT count(*) INTO v_audit FROM remittance_admin_audit WHERE row_id = v_op;
  SELECT count(*) INTO v_notif FROM notifications WHERE conversation_id = v_conv;
  v_before := pg_temp.op_updates();
  PERFORM cerebro_guardar_beneficiario(v_conv, '', '', '53821203', 'x2');
  v_after := pg_temp.op_updates();
  IF v_after <= v_before THEN
    RAISE EXCEPTION 'case 1: a phone saved by the bot did not UPDATE its operation (% -> %): the panel gets no Realtime event',
      v_before, v_after;
  END IF;

  -- 2. The touch changes nothing else on the operation: no field, no lock, no audit, no notification.
  SELECT to_jsonb(o) - 'updated_at' - 'version' INTO v_snap2 FROM remittance_operations o WHERE o.id = v_op;
  IF v_snap2 IS DISTINCT FROM v_snap THEN RAISE EXCEPTION 'case 2: the operation changed: % -> %', v_snap, v_snap2; END IF;
  IF (SELECT count(*) FROM remittance_admin_audit WHERE row_id = v_op) <> v_audit THEN
    RAISE EXCEPTION 'case 2: the touch wrote an audit row'; END IF;
  IF (SELECT count(*) FROM notifications WHERE conversation_id = v_conv) <> v_notif THEN
    RAISE EXCEPTION 'case 2: the touch sent a notification'; END IF;

  -- 3. A reparto slot completed by the bot touches the operation too.
  v_conv := pg_temp.conv_t186('03');
  PERFORM cerebro_guardar_reparto(v_conv, c1, '', '', c2, '', '', '', '', '', 'x1');
  v_before := pg_temp.op_updates();
  PERFORM cerebro_guardar_reparto(v_conv, '', '53821203', '', '', '', '', '', '', '', 'x2');
  v_after := pg_temp.op_updates();
  IF v_after <= v_before THEN RAISE EXCEPTION 'case 3: a reparto phone did not UPDATE its operation (% -> %)', v_before, v_after; END IF;

  -- 4. An operation with a human-locked field is still touched, and the lock guard writes no audit.
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;
  UPDATE remittance_operations SET admin_locked_fields = '{"quoted_source_amount": {"by": "test"}}'::jsonb WHERE id = v_op;
  SELECT count(*) INTO v_audit FROM remittance_admin_audit WHERE row_id = v_op;
  v_before := pg_temp.op_updates();
  PERFORM cerebro_guardar_reparto(v_conv, '', '', '', '', '53821204', '', '', '', '', 'x3');
  v_after := pg_temp.op_updates();
  IF v_after <= v_before THEN RAISE EXCEPTION 'case 4: a locked operation was not touched (% -> %)', v_before, v_after; END IF;
  IF (SELECT count(*) FROM remittance_admin_audit WHERE row_id = v_op) <> v_audit THEN
    RAISE EXCEPTION 'case 4: the touch of a locked operation wrote an audit row'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
