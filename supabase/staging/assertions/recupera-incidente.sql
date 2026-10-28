\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 344 (the bot corrects an incident that applied
-- nothing and holds no money; anything with money or another reason stays).
-- Self-reverting: BEGIN ... RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh.
-- =====================================================================

CREATE FUNCTION pg_temp.t_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990434' || lpad(p_n::text, 4, '0'), 'PRUEBA 344 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

-- An incident that applied nothing, with a phone-only card recipient (the shape
-- the production test left behind).
CREATE FUNCTION pg_temp.t_incidente(p_conv record, p_motivo text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type,
                                     source_currency, quoted_source_amount, incident_reason)
  VALUES (gen_random_uuid(), p_conv.acc, p_conv.conv, p_conv.contact, 'incident', 'remesa',
          'GYD', 1000, p_motivo)
  RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position,
                                        block_index, source, status)
  VALUES (v_op, 'cuban_card', NULL, '53821203', 1, 1, 'notes_parse', 'vigente');
  RETURN v_op;
END $f$;

DO $$
DECLARE
  c      record;
  v_op   uuid;
  v_r    jsonb;
  v_status text;
  v_motivo text;
BEGIN
  -- Deterministic: no live promo in this check.
  DELETE FROM promo_etecsa;

  -- 1-5. incident no_aplica, no money: the bot corrects it and the phone becomes the
  -- number of the saldo movil.
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_op := pg_temp.t_incidente(c, 'no_aplica');
  PERFORM pg_temp.t_eq('1 recoverable', cerebro_op_recuperable(v_op)::text, 'true');
  v_r := cerebro_cambiar_servicio(c.conv, 'saldo', 'test-344-a');
  PERFORM pg_temp.t_eq('2 change accepted', coalesce(v_r ->> 'ok', 'false'), 'true');
  PERFORM pg_temp.t_eq('3 service changed', coalesce(v_r ->> 'changed', 'false'), 'true');
  SELECT status, incident_reason INTO v_status, v_motivo FROM remittance_operations WHERE id = v_op;
  PERFORM pg_temp.t_eq('4 back to collecting', v_status, 'collecting_information');
  PERFORM pg_temp.t_eq('5 incident cleared', coalesce(v_motivo, '-'), '-');
  PERFORM pg_temp.t_eq('6 phone kept as the number',
    (SELECT string_agg(beneficiary_type || ':' || phone, ',' ORDER BY position)
       FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), 'recarga:53821203');
  PERFORM pg_temp.t_eq('7 service type is saldo',
    (SELECT service_type FROM remittance_operations WHERE id = v_op), 'saldo');

  -- 8. incident no_aplica WITH a consumed deposit: a person decides.
  SELECT * INTO c FROM pg_temp.t_conv(2);
  v_op := pg_temp.t_incidente(c, 'no_aplica');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('PRUEBA34401', 1000, 'GYD', 'prueba', now(), now(), v_op);
  PERFORM pg_temp.t_eq('8 money blocks recovery', cerebro_op_recuperable(v_op)::text, 'false');
  v_r := cerebro_cambiar_servicio(c.conv, 'saldo', 'test-344-b');
  PERFORM pg_temp.t_eq('9 change refused', coalesce(v_r ->> 'reason', '-'), 'estado_no_permite');
  PERFORM pg_temp.t_eq('10 still incident',
    (SELECT status FROM remittance_operations WHERE id = v_op), 'incident');

  -- 11. incident with another reason: a person decides.
  SELECT * INTO c FROM pg_temp.t_conv(3);
  v_op := pg_temp.t_incidente(c, 'comprobante_dudoso');
  PERFORM pg_temp.t_eq('11 other reason blocks recovery', cerebro_op_recuperable(v_op)::text, 'false');
  v_r := cerebro_cambiar_servicio(c.conv, 'saldo', 'test-344-c');
  PERFORM pg_temp.t_eq('12 change refused', coalesce(v_r ->> 'reason', '-'), 'estado_no_permite');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
