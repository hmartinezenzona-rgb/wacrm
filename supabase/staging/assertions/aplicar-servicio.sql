\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 266 (cerebro_aplicar_servicio: the writer side of the service resolver; the core keeps a lone
-- phone-only recipient as a recarga number).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT) or by hand as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- Prerequisite: 265 (cerebro_resolver_servicio). Synthetic fixtures only: contacts 'PRUEBA aplicar N', phones 5990254xxxx,
-- fake mobiles 5550xxxx and a fake card, no customer data.
-- odd/tasks/service-resolution.md (S3 part 1) with the owner answers Q1, Q3, Q6, Q8.
-- Cases (number = label in the failure message):
--   1  Katiuska (1232671b): phone-only remesa holding 6,200 + promo, no words -> aplicado, recarga, phone kept as a recarga
--      number, receipt still linked, audit automation_service_change by automation:resolver, partial recipient kept
--   2  the same with an empty recarga duplicate holding another number -> duplicate cancelled, number moved, audit rows
--   3  the duplicate holds the SAME number the holder already has -> the moved one is retired (dedupe), holder has it once
--   4  Q8: "mejor a esta tarjeta <card>" on a recarga holder -> converts to cuban_card
--   5  ninguna / adicional / preguntar -> aplicado false, nothing changed;  6 mixed group untouched;  7 human lock untouched
--   8  agent actor -> action agent_service_change, the lock left names an automation actor (not a human lock)
--   9  advisory lock: a second call in the same transaction is idempotent;  10 error path returns safe JSON, rolls back
--   11 null / unknown conversation;  12 ACL and shape;  13 an authenticated caller must belong to the account
--   14 panel path crm_cambiar_servicio: a recipient WITH a card is retired (unchanged), a lone phone-only one is kept as a
--      recarga number (new), saldo keeps it too, every phone-only recipient is kept as a recarga number
-- =====================================================================

CREATE FUNCTION pg_temp.a_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990254' || lpad(p_n::text, 4, '0'), 'PRUEBA aplicar ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.a_op(p_c record, p_status text, p_svc text, p_rail text, p_amt numeric, p_receipt boolean DEFAULT false) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, p_status, p_svc, p_rail, 'GYD', p_amt, clock_timestamp()) RETURNING id INTO v_op;
  IF p_receipt THEN
    INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, source)
    VALUES (v_op, p_c.conv, 'R266-' || substr(v_op::text, 1, 8), p_amt, 'GYD', 'bot');
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.a_msg(p_conv uuid, p_txt text) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (p_conv, 'customer', 'text', p_txt, clock_timestamp());
$f$;

CREATE FUNCTION pg_temp.a_parcial(p_conv uuid, p_tarjeta text, p_celular text) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, tarjeta, celular, actualizado) VALUES (p_conv, p_tarjeta, p_celular, clock_timestamp())
  ON CONFLICT (conversation_id) DO UPDATE SET tarjeta = EXCLUDED.tarjeta, celular = EXCLUDED.celular, actualizado = EXCLUDED.actualizado;
$f$;

CREATE FUNCTION pg_temp.a_ben(p_op uuid, p_type text, p_card text, p_phone text, p_pos int DEFAULT 1,
                              p_amount numeric DEFAULT NULL, p_cur text DEFAULT NULL, p_dm text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status,
                                        amount, currency, amount_origin, delivery_method)
  VALUES (p_op, p_type, p_card, p_phone, p_pos, p_pos, 'test266', 'vigente', p_amount, p_cur,
          CASE WHEN p_amount IS NOT NULL THEN 'calculated' END, p_dm) RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

CREATE FUNCTION pg_temp.a_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

-- accion / motivo / aplicado of an apply result
CREATE FUNCTION pg_temp.a_chk(p_label text, p_got jsonb, p_accion text, p_motivo text, p_aplicado boolean) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got ->> 'accion' IS DISTINCT FROM p_accion OR p_got ->> 'motivo' IS DISTINCT FROM p_motivo
     OR (p_got ->> 'aplicado')::boolean IS DISTINCT FROM p_aplicado THEN
    RAISE EXCEPTION 'case %: expected % / % / aplicado %, got %', p_label, p_accion, p_motivo, p_aplicado, p_got - 'operaciones';
  END IF;
END $f$;

CREATE FUNCTION pg_temp.a_audit(p_row uuid, p_field text, p_action text, p_actor text) RETURNS bigint
LANGUAGE sql AS $f$
  SELECT count(*) FROM remittance_admin_audit WHERE row_id = p_row AND field_name = p_field AND action = p_action AND actor = p_actor;
$f$;

-- 'type(count)' of the vigente recipients of an operation, e.g. 'recarga:2'; 'none' when it has none
CREATE FUNCTION pg_temp.a_vig(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(t || ':' || n, ',' ORDER BY t), 'none')
    FROM (SELECT beneficiary_type t, count(*) n FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente' GROUP BY 1) q;
$f$;

CREATE FUNCTION pg_temp.a_boom() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN RAISE EXCEPTION 'boom 266' USING ERRCODE = 'XX999'; END $f$;

DO $$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
  c record; v_op uuid; v_dup uuid; v_ben uuid; v_ben2 uuid; v_r jsonb; v_o remittance_operations%ROWTYPE;
  v_cup numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  c_card constant text := '9999000000000002';
  v_stranger uuid := gen_random_uuid();
  v_n int;
BEGIN
  -- A promo running whose recarga price is 6,200 (min_cup 600); every other promo is out of the way.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT 266', 'https://assert.invalid/266', 'assert', md5('assert-266-vigente'), 'confirmada');
  IF (SELECT precio_gyd FROM cerebro_promo_vigente()) IS DISTINCT FROM 6200 THEN RAISE EXCEPTION 'fixture: promo price is not 6200'; END IF;

  -- ---- 1. Katiuska (1232671b): a 6,200 receipt + a phone-only recipient, no words ------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(1);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55501001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM pg_temp.a_parcial(c.conv, NULL, '55501001');
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('1', v_r, 'convertir', 'monto_precio_y_celular', true);
  PERFORM pg_temp.a_eq('1 op id', v_r #>> '{cambios,operacion}', v_op::text);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  PERFORM pg_temp.a_eq('1 service', v_o.service_type, 'recarga');
  PERFORM pg_temp.a_eq('1 delivery_method', v_o.delivery_method, NULL);
  PERFORM pg_temp.a_eq('1 status untouched', v_o.status, 'deposit_verification');
  PERFORM pg_temp.a_eq('1 recipients', pg_temp.a_vig(v_op), 'recarga:1');
  PERFORM pg_temp.a_eq('1 same recipient row kept', (SELECT id::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), v_ben::text);
  PERFORM pg_temp.a_eq('1 phone kept', (SELECT phone FROM remittance_beneficiaries WHERE id = v_ben), '55501001');
  PERFORM pg_temp.a_eq('1 amount cleared', (SELECT coalesce(amount::text, '-') || '/' || coalesce(currency, '-') || '/' || coalesce(amount_origin, '-') || '/' || coalesce(delivery_method, '-')
                                              FROM remittance_beneficiaries WHERE id = v_ben), '-/-/-/-');
  PERFORM pg_temp.a_eq('1 retyped list', v_r #>> '{cambios,reetiquetados}', jsonb_build_array(v_ben)::text);
  PERFORM pg_temp.a_eq('1 nothing retired', v_r #>> '{cambios,retirados}', '[]');
  PERFORM pg_temp.a_eq('1 deposit still linked', (SELECT count(*)::text FROM remittance_operation_receipts WHERE operation_id = v_op), '1');
  PERFORM pg_temp.a_eq('1 audit service', pg_temp.a_audit(v_op, 'service', 'automation_service_change', 'automation:resolver')::text, '1');
  PERFORM pg_temp.a_eq('1 lock names an automation actor', v_o.admin_locked_fields #>> '{service_type,by}', 'automation:resolver');
  PERFORM pg_temp.a_eq('1 partial recipient untouched', (SELECT celular FROM cerebro_beneficiario_parcial WHERE conversation_id = c.conv), '55501001');
  PERFORM pg_temp.a_eq('1 guc restored', coalesce(current_setting('wacrm.origin', true), ''), '');
  PERFORM pg_temp.a_eq('1 guc actor restored', coalesce(current_setting('wacrm.actor', true), ''), '');

  -- ---- 9. a second call in the same transaction is idempotent (the lock is held, the resolver sees a recarga) -------------------------
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('9 second call', v_r, 'ninguna', 'sin_cambio', false);
  PERFORM pg_temp.a_eq('9 still recarga', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'recarga');
  PERFORM pg_temp.a_eq('9 one audit row', pg_temp.a_audit(v_op, 'service', 'automation_service_change', 'automation:resolver')::text, '1');
  PERFORM pg_temp.a_eq('9 one recipient', pg_temp.a_vig(v_op), 'recarga:1');

  -- ---- 2. the same with an empty recarga the agent opened next to the holder ---------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(2);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', 'cuban_card', 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55502001', 1, 1200, 'CUP', 'cuban_card');
  v_dup := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  v_ben2 := pg_temp.a_ben(v_dup, 'recarga', NULL, '55502002', 1);
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');
  PERFORM pg_temp.a_parcial(c.conv, NULL, '55502002');
  v_r := cerebro_aplicar_servicio(c.conv, NULL, NULL, 'automation:resolver', 'exec266-2');
  PERFORM pg_temp.a_chk('2', v_r, 'convertir', 'palabras', true);
  PERFORM pg_temp.a_eq('2 holder is a recarga', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'recarga');
  PERFORM pg_temp.a_eq('2 canceladas', v_r #>> '{cambios,canceladas}', jsonb_build_array(v_dup)::text);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_dup;
  PERFORM pg_temp.a_eq('2 duplicate cancelled', v_o.status || '/' || (v_o.cancelled_at IS NOT NULL)::text, 'cancelled/true');
  PERFORM pg_temp.a_eq('2 holder numbers', (SELECT string_agg(phone, ',' ORDER BY position) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'),
                       '55502001,55502002');
  PERFORM pg_temp.a_eq('2 positions distinct', (SELECT count(DISTINCT position)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), '2');
  PERFORM pg_temp.a_eq('2 moved row', (SELECT operation_id::text FROM remittance_beneficiaries WHERE id = v_ben2), v_op::text);
  PERFORM pg_temp.a_eq('2 duplicate keeps no live recipient', pg_temp.a_vig(v_dup), 'none');
  PERFORM pg_temp.a_eq('2 numeros_movidos', v_r #>> '{cambios,numeros_movidos}', jsonb_build_array(v_ben2)::text);
  PERFORM pg_temp.a_eq('2 audit service', pg_temp.a_audit(v_op, 'service', 'automation_service_change', 'automation:resolver')::text, '1');
  PERFORM pg_temp.a_eq('2 audit cancelled op', pg_temp.a_audit(v_dup, 'status', 'automation_service_change', 'automation:resolver')::text, '1');
  PERFORM pg_temp.a_eq('2 audit moved recipient', pg_temp.a_audit(v_ben2, 'operation_id', 'automation_service_change', 'automation:resolver')::text, '1');
  PERFORM pg_temp.a_eq('2 audit names the execution', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id IN (v_op, v_dup, v_ben2) AND reason LIKE '%exec266-2%'), '3');
  PERFORM pg_temp.a_eq('2 partial recipient put back', (SELECT celular FROM cerebro_beneficiario_parcial WHERE conversation_id = c.conv), '55502002');
  -- the cancelled duplicate is no longer a candidate: a second call does nothing
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_eq('2 second call applies nothing', v_r ->> 'aplicado', 'false');

  -- ---- 3. dedupe: the duplicate holds the number the holder already has --------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(3);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55503001', 1, 1200, 'CUP', 'cuban_card');
  v_dup := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  v_ben2 := pg_temp.a_ben(v_dup, 'recarga', NULL, '55503001', 1);
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('3', v_r, 'convertir', 'palabras', true);
  PERFORM pg_temp.a_eq('3 holder has the number once', (SELECT count(*)::text FROM remittance_beneficiaries
                         WHERE operation_id = v_op AND status = 'vigente' AND phone = '55503001'), '1');
  PERFORM pg_temp.a_eq('3 moved one retired in place', (SELECT status || '/' || operation_id::text FROM remittance_beneficiaries WHERE id = v_ben2), 'reemplazado/' || v_dup::text);
  PERFORM pg_temp.a_eq('3 duplicados_retirados', v_r #>> '{cambios,duplicados_retirados}', jsonb_build_array(v_ben2)::text);
  PERFORM pg_temp.a_eq('3 numeros_movidos', v_r #>> '{cambios,numeros_movidos}', '[]');
  PERFORM pg_temp.a_eq('3 duplicate cancelled', (SELECT status FROM remittance_operations WHERE id = v_dup), 'cancelled');
  PERFORM pg_temp.a_eq('3 audit retired recipient', pg_temp.a_audit(v_ben2, 'status', 'automation_service_change', 'automation:resolver')::text, '1');
  PERFORM pg_temp.a_eq('3 audit cancelled op', pg_temp.a_audit(v_dup, 'status', 'automation_service_change', 'automation:resolver')::text, '1');
  PERFORM pg_temp.a_eq('3 holder rows', pg_temp.a_vig(v_op), 'recarga:1');

  -- ---- 4. Q8: "mejor a esta tarjeta <card>" on a recarga holder converts it to a CUP card --------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(4);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'recarga', NULL, 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'recarga', NULL, '55504001', 1);
  v_r := cerebro_aplicar_servicio(c.conv, NULL, 'mejor a esta tarjeta ' || c_card);
  PERFORM pg_temp.a_chk('4', v_r, 'convertir', 'palabras', true);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  PERFORM pg_temp.a_eq('4 service', v_o.service_type || '/' || coalesce(v_o.delivery_method, '-'), 'remesa/cuban_card');
  PERFORM pg_temp.a_eq('4 recarga number retired', (SELECT status FROM remittance_beneficiaries WHERE id = v_ben), 'reemplazado');
  PERFORM pg_temp.a_eq('4 retirados', v_r #>> '{cambios,retirados}', jsonb_build_array(v_ben)::text);
  PERFORM pg_temp.a_eq('4 audit', pg_temp.a_audit(v_op, 'service', 'automation_service_change', 'automation:resolver')::text, '1');
  PERFORM pg_temp.a_eq('4 deposit still linked', (SELECT count(*)::text FROM remittance_operation_receipts WHERE operation_id = v_op), '1');

  -- ---- 5. ninguna / adicional / preguntar change nothing ------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(5);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  v_dup := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('5 ninguna', v_r, 'ninguna', 'sin_cambio', false);
  PERFORM pg_temp.a_eq('5 ninguna cambios', v_r ->> 'cambios', '{}');
  PERFORM pg_temp.a_eq('5 ninguna remesa', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');
  PERFORM pg_temp.a_eq('5 ninguna empty op open', (SELECT status FROM remittance_operations WHERE id = v_dup), 'collecting_information');
  PERFORM pg_temp.a_eq('5 ninguna no audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id IN (v_op, v_dup)), '0');

  SELECT * INTO c FROM pg_temp.a_conv(6);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', v_cup + 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  PERFORM pg_temp.a_msg(c.conv, 'y ademas una recarga');
  v_dup := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('5 adicional', v_r, 'adicional', 'deposito_cubre_ambos', false);
  PERFORM pg_temp.a_eq('5 adicional holder', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');
  PERFORM pg_temp.a_eq('5 adicional empty recarga stays open', (SELECT status FROM remittance_operations WHERE id = v_dup), 'collecting_information');
  PERFORM pg_temp.a_eq('5 adicional no audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id IN (v_op, v_dup)), '0');

  SELECT * INTO c FROM pg_temp.a_conv(7);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 25000, true);
  PERFORM pg_temp.a_msg(c.conv, 'una recarga y un combo');
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('5 preguntar', v_r, 'preguntar', 'palabras_ambiguas', false);
  PERFORM pg_temp.a_eq('5 preguntar holder', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');
  PERFORM pg_temp.a_eq('5 preguntar keeps the question', jsonb_typeof(v_r -> 'pregunta'), 'object');

  -- ---- 6. a mixed group is untouched (changes go through repartir_envio) ---------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(8);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', 'clasica', 18200, true);
  v_dup := pg_temp.a_op(c, 'ready_to_transfer', 'recarga', NULL, 6200, false);
  UPDATE remittance_operations SET mixed_group_id = v_op WHERE id IN (v_op, v_dup);
  PERFORM pg_temp.a_msg(c.conv, 'clasica y una recarga');
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('6', v_r, 'ninguna', 'grupo_mixto', false);
  PERFORM pg_temp.a_eq('6 services', (SELECT string_agg(service_type, ',' ORDER BY service_type) FROM remittance_operations WHERE conversation_id = c.conv), 'recarga,remesa');
  PERFORM pg_temp.a_eq('6 both open', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND status = 'ready_to_transfer'), '2');

  -- ---- 7. a human lock is untouched ----------------------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(9);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations
     SET admin_locked_fields = jsonb_build_object('service_type', jsonb_build_object('by', 'user:test266', 'at', now()))
   WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('7', v_r, 'ninguna', 'bloqueada', false);
  PERFORM pg_temp.a_eq('7 untouched', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');

  -- ---- 8. an agent caller: audit action agent_service_change; the lock it leaves is not a human lock ------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(10);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55510001', 1, 1200, 'CUP', 'cuban_card');
  v_r := cerebro_aplicar_servicio(c.conv, NULL, NULL, 'agent:registrar_numeros_recarga', 'exec266-8');
  PERFORM pg_temp.a_chk('8', v_r, 'convertir', 'monto_precio_y_celular', true);
  PERFORM pg_temp.a_eq('8 audit action', pg_temp.a_audit(v_op, 'service', 'agent_service_change', 'agent:registrar_numeros_recarga')::text, '1');
  PERFORM pg_temp.a_eq('8 no automation action', pg_temp.a_audit(v_op, 'service', 'automation_service_change', 'agent:registrar_numeros_recarga')::text, '0');
  PERFORM pg_temp.a_eq('8 lock actor', (SELECT admin_locked_fields #>> '{service_type,by}' FROM remittance_operations WHERE id = v_op), 'automation:agent_registrar_numeros_recarga');
  PERFORM pg_temp.a_eq('8 not a human lock', cerebro_resolver_servicio(c.conv) ->> 'motivo', 'sin_cambio');
  -- a human caller keeps the human audit action
  SELECT * INTO c FROM pg_temp.a_conv(11);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55511001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM cerebro_aplicar_servicio(c.conv, NULL, NULL, 'user:ana');
  PERFORM pg_temp.a_eq('8 human action', pg_temp.a_audit(v_op, 'service', 'human_correction', 'user:ana')::text, '1');

  -- ---- 10. error path: the whole call is undone and the resolver's answer comes back with the sqlstate -----------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(12);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55512001', 1, 1200, 'CUP', 'cuban_card');
  CREATE TRIGGER a_boom BEFORE UPDATE OF service_type ON remittance_operations
    FOR EACH ROW WHEN (NEW.service_type = 'recarga') EXECUTE FUNCTION pg_temp.a_boom();
  v_r := cerebro_aplicar_servicio(c.conv);
  DROP TRIGGER a_boom ON remittance_operations;
  PERFORM pg_temp.a_chk('10', v_r, 'convertir', 'monto_precio_y_celular', false);
  PERFORM pg_temp.a_eq('10 sqlstate', v_r ->> 'sqlstate', 'XX999');
  PERFORM pg_temp.a_eq('10 cambios', v_r ->> 'cambios', '{}');
  PERFORM pg_temp.a_eq('10 still remesa', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');
  PERFORM pg_temp.a_eq('10 recipient intact', (SELECT beneficiary_type || '/' || status FROM remittance_beneficiaries WHERE id = v_ben), 'cuban_card/vigente');
  PERFORM pg_temp.a_eq('10 no audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_op), '0');
  PERFORM pg_temp.a_eq('10 guc origin', coalesce(current_setting('wacrm.origin', true), ''), '');
  PERFORM pg_temp.a_eq('10 guc actor', coalesce(current_setting('wacrm.actor', true), ''), '');
  -- and the same call works once the fault is gone (the lock was released by the sub-transaction, not leaked)
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('10 retry', v_r, 'convertir', 'monto_precio_y_celular', true);

  -- ---- 11. no conversation / unknown conversation ----------------------------------------------------------------------------------------------------
  v_r := cerebro_aplicar_servicio(NULL);
  PERFORM pg_temp.a_chk('11 null', v_r, 'ninguna', 'sin_conversacion', false);
  v_r := cerebro_aplicar_servicio(gen_random_uuid());
  PERFORM pg_temp.a_chk('11 unknown', v_r, 'ninguna', 'sin_cambio', false);

  -- ---- 12. ACL and shape --------------------------------------------------------------------------------------------------------------------------
  IF has_function_privilege('anon', 'public.cerebro_aplicar_servicio(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 12: anon can execute'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x WHERE p.proname = 'cerebro_aplicar_servicio' AND x.grantee = 0) THEN
    RAISE EXCEPTION 'case 12: PUBLIC can execute'; END IF;
  IF NOT has_function_privilege('service_role', 'public.cerebro_aplicar_servicio(uuid,text,text,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cerebro_aplicar_servicio(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 12: authenticated / service_role cannot execute'; END IF;
  IF (SELECT p.provolatile::text || p.prosecdef::text FROM pg_proc p WHERE p.proname = 'cerebro_aplicar_servicio') IS DISTINCT FROM 'vtrue' THEN
    RAISE EXCEPTION 'case 12: not VOLATILE SECURITY DEFINER'; END IF;
  -- the core keeps its live ACL (owner only)
  IF has_function_privilege('anon', 'public._cambiar_servicio_core(uuid,text,text,text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._cambiar_servicio_core(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 12: the core became callable'; END IF;

  -- ---- 13. an authenticated caller must belong to the conversation's account ------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(13);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55513001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_chk('13 stranger', v_r, 'ninguna', 'no_autorizado', false);
  PERFORM pg_temp.a_eq('13 stranger changed nothing', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_chk('13 member', v_r, 'convertir', 'monto_precio_y_celular', true);

  -- ---- 14. the panel path (crm_cambiar_servicio) through the shared core ---------------------------------------------------------------------------
  -- a recipient WITH a card is retired when the remesa becomes a recarga (unchanged behaviour)
  SELECT * INTO c FROM pg_temp.a_conv(14);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', c_card, '55514001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  PERFORM crm_cambiar_servicio(v_op, 'recarga');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('14 card recipient retired', pg_temp.a_vig(v_op) || '/' || (SELECT status FROM remittance_beneficiaries WHERE id = v_ben), 'none/reemplazado');
  -- a lone phone-only recipient is kept as a recarga number (re-typed, priced fields cleared)
  SELECT * INTO c FROM pg_temp.a_conv(15);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55515001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  v_r := crm_cambiar_servicio(v_op, 'recarga');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('14 phone-only kept', pg_temp.a_vig(v_op), 'recarga:1');
  PERFORM pg_temp.a_eq('14 same row', (SELECT status || '/' || phone || '/' || coalesce(amount::text, '-') FROM remittance_beneficiaries WHERE id = v_ben), 'vigente/55515001/-');
  PERFORM pg_temp.a_eq('14 panel counts', (v_r ->> 'retired_recipients') || '/' || (v_r ->> 'retyped_recipients'), '0/1');
  PERFORM pg_temp.a_eq('14 human audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service' AND action = 'human_correction'), '1');
  -- saldo keeps it too (stored as beneficiary_type recarga)
  SELECT * INTO c FROM pg_temp.a_conv(16);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55516001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  PERFORM crm_cambiar_servicio(v_op, 'saldo');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('14 saldo keeps it', (SELECT service_type FROM remittance_operations WHERE id = v_op) || '/' || pg_temp.a_vig(v_op), 'saldo/recarga:1');
  -- every phone-only recipient is a number of the recarga (a recarga may go to several numbers): all are kept
  SELECT * INTO c FROM pg_temp.a_conv(17);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55517001', 1);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55517002', 2);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  PERFORM crm_cambiar_servicio(v_op, 'recarga');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('14 two phones kept as numbers', pg_temp.a_vig(v_op), 'recarga:2');
  -- a lone phone-only recipient does not survive a change to a card rail (the target is not recarga / saldo)
  SELECT * INTO c FROM pg_temp.a_conv(18);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55518001', 1);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  PERFORM crm_cambiar_servicio(v_op, 'zelle');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('14 zelle retires the mobile', pg_temp.a_vig(v_op), 'none');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
