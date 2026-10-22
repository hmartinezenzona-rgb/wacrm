\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 266 (cerebro_aplicar_servicio, contract v2: the agent declares intent, the database checks money,
-- data and state and executes). Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in
-- RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT) or by hand as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- Prerequisites: 265 (cerebro_resolver_servicio, cerebro_declarar_servicio), 255 (cerebro_repartir_envio), 230 (crm_cambiar_servicio).
-- Synthetic fixtures only: contacts 'PRUEBA aplicar N', phones 5990254xxxx, fake mobiles 5550xxxx and a fake card.
-- odd/tasks/service-resolution.md (REDESIGN 2026-10-22; owner answers Q1, Q3, Q5, Q7, Q8).
-- Cases (number = label in the failure message):
--   1  Katiuska 14:30 (real shape): remesa holding 6,200 with a phone-only cuban_card recipient, no declaration -> convertir
--      to recarga; the number is kept as a vigente 'recarga' recipient; deposit still linked; audit automation_service_change
--   2  14:32 agent cambiar recarga on a card remesa holding 6,200 -> convertir; declaration persisted; audit agent_service_change;
--      the lock names automation:agent_cambiar_servicio (not a human lock); a second call changes nothing
--   3  cambiar recarga with two empty recarga duplicates next to the holder -> both cancelled, numbers moved, the same number
--      never ends twice on the holder
--   4  agregar recarga on a card remesa holding 5,000 (below the sum of minimums) -> aparte: a new recarga operation,
--      collecting_information, 0 GYD, same conversation, not grouped; the holder untouched
--   5  agregar recarga on a card remesa holding 13,000 -> mixto through cerebro_repartir_envio (255): one group with the
--      holder (6,800) and the recarga (6,200); a second call changes nothing
--   6  cambiar recarga with 5,000 -> nothing changed, aplicado false, mensaje present
--   7  Q8: a recarga holder with 6,200 and cambiar cuban_card -> convertir to a card remesa; the recarga numbers retired
--   8  a mixed group is untouched (grupo_mixto)
--   9  a human lock is untouched (bloqueada)
--   10 a human caller keeps the human audit action (human_correction); a declaration with a non-agent actor is not stored
--   11 error path: a fault inside the call undoes it and returns the resolver JSON with the sqlstate; a retry works
--   12 null / unknown conversation; an invalid declared service ('remesa') is refused and not stored
--   13 ACL: service_role only (no PUBLIC, anon, authenticated); VOLATILE SECURITY DEFINER; the core keeps its owner-only ACL
--   14 an authenticated caller must belong to the conversation's account (auth.uid() check kept)
--   15 panel path crm_cambiar_servicio (shared core): a recipient WITH a card is retired on remesa -> recarga, a lone
--      phone-only one is kept as a recarga number, saldo keeps it, every phone-only recipient is kept
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

-- 'type:count' of the vigente recipients of an operation, e.g. 'recarga:2'; 'none' when it has none
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
  c record; v_op uuid; v_dup uuid; v_dup2 uuid; v_nueva uuid; v_ben uuid; v_ben2 uuid; v_ben3 uuid;
  v_r jsonb; v_r2 jsonb; v_o remittance_operations%ROWTYPE;
  v_cup numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  c_card constant text := '9999000000000002';
  v_stranger uuid := gen_random_uuid();
BEGIN
  -- A promo running whose recarga price is 6,200 (min_cup 600); every other promo is out of the way.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT 266', 'https://assert.invalid/266', 'assert', md5('assert-266-vigente'), 'confirmada');
  IF (SELECT precio_gyd FROM cerebro_promo_vigente()) IS DISTINCT FROM 6200 THEN RAISE EXCEPTION 'fixture: promo price is not 6200'; END IF;

  -- ---- 1. Katiuska 14:30: a 6,200 receipt, a phone-only recipient, no declaration, no words ----------------------------------------
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
  PERFORM pg_temp.a_eq('1 nothing retired', v_r #>> '{cambios,retirados}', '[]');
  PERFORM pg_temp.a_eq('1 deposit still linked', (SELECT count(*)::text FROM remittance_operation_receipts WHERE operation_id = v_op), '1');
  PERFORM pg_temp.a_eq('1 audit service', pg_temp.a_audit(v_op, 'service', 'automation_service_change', 'automation:resolver')::text, '1');
  PERFORM pg_temp.a_eq('1 lock names an automation actor', v_o.admin_locked_fields #>> '{service_type,by}', 'automation:resolver');
  PERFORM pg_temp.a_eq('1 partial recipient untouched', (SELECT celular FROM cerebro_beneficiario_parcial WHERE conversation_id = c.conv), '55501001');
  PERFORM pg_temp.a_eq('1 guc restored', coalesce(current_setting('wacrm.origin', true), ''), '');
  PERFORM pg_temp.a_eq('1 guc actor restored', coalesce(current_setting('wacrm.actor', true), ''), '');
  -- a second call in the same transaction changes nothing
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('1 second call', v_r, 'ninguna', 'sin_cambio', false);
  PERFORM pg_temp.a_eq('1 one audit row', pg_temp.a_audit(v_op, 'service', 'automation_service_change', 'automation:resolver')::text, '1');

  -- ---- 2. 14:32: the agent declares 'recarga' and changes the card remesa holding 6,200 to it --------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(2);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL, 1, 1200, 'CUP', 'cuban_card');
  v_r := cerebro_aplicar_servicio(c.conv, 'recarga', 'cambiar', 'agent:cambiar_servicio', 'exec266-b');
  PERFORM pg_temp.a_chk('2', v_r, 'convertir', 'declarado', true);
  PERFORM pg_temp.a_eq('2 holder recarga', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'recarga');
  PERFORM pg_temp.a_eq('2 declaration persisted', (SELECT servicio || '/' || actor FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), 'recarga/agent:cambiar_servicio');
  PERFORM pg_temp.a_eq('2 card recipient retired', (SELECT status FROM remittance_beneficiaries WHERE id = v_ben), 'reemplazado');
  PERFORM pg_temp.a_eq('2 recipients', pg_temp.a_vig(v_op), 'none');
  PERFORM pg_temp.a_eq('2 deposit still linked', (SELECT count(*)::text FROM remittance_operation_receipts WHERE operation_id = v_op), '1');
  PERFORM pg_temp.a_eq('2 audit agent action', pg_temp.a_audit(v_op, 'service', 'agent_service_change', 'agent:cambiar_servicio')::text, '1');
  PERFORM pg_temp.a_eq('2 no automation action for the agent', pg_temp.a_audit(v_op, 'service', 'automation_service_change', 'agent:cambiar_servicio')::text, '0');
  PERFORM pg_temp.a_eq('2 lock names the agent tool, not a human', (SELECT admin_locked_fields #>> '{service_type,by}' FROM remittance_operations WHERE id = v_op),
                       'automation:agent_cambiar_servicio');
  PERFORM pg_temp.a_eq('2 resolver: not a human lock', cerebro_resolver_servicio(c.conv) ->> 'motivo', 'sin_cambio');
  -- idempotent: the second call changes nothing and writes no audit row
  v_r := cerebro_aplicar_servicio(c.conv, 'recarga', 'cambiar', 'agent:cambiar_servicio', 'exec266-b2');
  PERFORM pg_temp.a_chk('2 again', v_r, 'ninguna', 'sin_cambio', false);
  PERFORM pg_temp.a_eq('2 again no audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service'), '1');

  -- ---- 3. cambiar recarga with two empty recarga duplicates: cancelled, numbers moved, no duplicate number ------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(3);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL, 1, 1200, 'CUP', 'cuban_card');
  v_dup := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  v_ben2 := pg_temp.a_ben(v_dup, 'recarga', NULL, '55503002', 1);
  v_dup2 := pg_temp.a_op(c, 'awaiting_deposit', 'recarga', NULL, 0, false);
  v_ben3 := pg_temp.a_ben(v_dup2, 'recarga', NULL, '55503002', 1);
  v_r := cerebro_aplicar_servicio(c.conv, 'recarga', 'cambiar', 'agent:cambiar_servicio', 'exec266-c');
  PERFORM pg_temp.a_chk('3', v_r, 'convertir', 'declarado', true);
  PERFORM pg_temp.a_eq('3 holder recarga', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'recarga');
  PERFORM pg_temp.a_eq('3 both duplicates cancelled', (SELECT count(*)::text FROM remittance_operations WHERE id IN (v_dup, v_dup2) AND status = 'cancelled'), '2');
  PERFORM pg_temp.a_eq('3 holder recipients', pg_temp.a_vig(v_op), 'recarga:1');
  PERFORM pg_temp.a_eq('3 the number once on the holder', (SELECT count(*)::text FROM remittance_beneficiaries
                         WHERE operation_id = v_op AND status = 'vigente' AND phone = '55503002'), '1');
  PERFORM pg_temp.a_eq('3 first copy moved', (SELECT operation_id::text FROM remittance_beneficiaries WHERE id = v_ben2), v_op::text);
  PERFORM pg_temp.a_eq('3 second copy retired in place', (SELECT status || '/' || operation_id::text FROM remittance_beneficiaries WHERE id = v_ben3),
                       'reemplazado/' || v_dup2::text);
  PERFORM pg_temp.a_eq('3 duplicates listed', v_r #>> '{cambios,duplicados_retirados}', jsonb_build_array(v_ben3)::text);
  PERFORM pg_temp.a_eq('3 card retired', (SELECT status FROM remittance_beneficiaries WHERE id = v_ben), 'reemplazado');
  PERFORM pg_temp.a_eq('3 audit cancelled duplicate', pg_temp.a_audit(v_dup, 'status', 'agent_service_change', 'agent:cambiar_servicio')::text, '1');
  PERFORM pg_temp.a_eq('3 audit moved recipient', pg_temp.a_audit(v_ben2, 'operation_id', 'agent_service_change', 'agent:cambiar_servicio')::text, '1');
  PERFORM pg_temp.a_eq('3 partial recipient put back', (SELECT count(*)::text FROM cerebro_beneficiario_parcial WHERE conversation_id = c.conv), '0');

  -- ---- 4. agregar recarga on a card remesa holding 5,000: aparte, a new separate operation, the holder untouched -------------------
  SELECT * INTO c FROM pg_temp.a_conv(4);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL, 1);
  v_r := cerebro_aplicar_servicio(c.conv, 'recarga', 'agregar', 'agent:agregar_servicio', 'exec266-d');
  PERFORM pg_temp.a_chk('4', v_r, 'aparte', 'adicional_aparte', true);
  v_nueva := (v_r #>> '{cambios,operacion}')::uuid;
  PERFORM pg_temp.a_eq('4 new operation', (SELECT service_type || '/' || status || '/' || quoted_source_amount::text || '/' || coalesce(mixed_group_id::text, '-')
                                             FROM remittance_operations WHERE id = v_nueva), 'recarga/collecting_information/0/-');
  PERFORM pg_temp.a_eq('4 same conversation, account and contact',
                       (SELECT (conversation_id = c.conv)::text || (account_id = c.acc)::text || (contact_id = c.contact)::text
                          FROM remittance_operations WHERE id = v_nueva), 'truetruetrue');
  PERFORM pg_temp.a_eq('4 holder untouched', (SELECT service_type || '/' || status || '/' || quoted_source_amount::text FROM remittance_operations WHERE id = v_op),
                       'remesa/deposit_verification/5000');
  PERFORM pg_temp.a_eq('4 holder recipient untouched', pg_temp.a_vig(v_op), 'cuban_card:1');
  PERFORM pg_temp.a_eq('4 audit on the new operation', pg_temp.a_audit(v_nueva, 'service_type', 'agent_service_change', 'agent:agregar_servicio')::text, '1');
  PERFORM pg_temp.a_eq('4 declaration persisted', (SELECT servicio FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), 'recarga');

  -- ---- 5. agregar recarga on a card remesa holding 13,000: mixto through the 255 split, one group ----------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(5);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 13000, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL, 1);
  v_r := cerebro_aplicar_servicio(c.conv, 'recarga', 'agregar', 'agent:agregar_servicio', 'exec266-e');
  PERFORM pg_temp.a_chk('5', v_r, 'mixto', 'deposito_cubre_ambos', true);
  PERFORM pg_temp.a_eq('5 one group', (SELECT count(DISTINCT mixed_group_id)::text FROM remittance_operations
                                        WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '1');
  PERFORM pg_temp.a_eq('5 group members and shares', (SELECT string_agg(service_type || ':' || quoted_source_amount::text, ',' ORDER BY service_type)
                                                        FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL),
                       'recarga:6200,remesa:6800');
  PERFORM pg_temp.a_eq('5 holder in the group', (SELECT (mixed_group_id IS NOT NULL)::text FROM remittance_operations WHERE id = v_op), 'true');
  PERFORM pg_temp.a_eq('5 split ran once', (SELECT count(*)::text FROM tool_execution_log WHERE conversation_id = c.conv AND tool_name = 'repartir_envio'), '1');
  PERFORM pg_temp.a_eq('5 split reply', v_r #>> '{cambios,operacion}', v_op::text);
  -- a second call: the mixed group is untouched
  v_r2 := cerebro_aplicar_servicio(c.conv, 'recarga', 'agregar', 'agent:agregar_servicio', 'exec266-e2');
  PERFORM pg_temp.a_chk('5 again', v_r2, 'ninguna', 'grupo_mixto', false);
  PERFORM pg_temp.a_eq('5 again: still two members', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '2');

  -- ---- 6. cambiar recarga with 5,000: below the promo price, nothing changes -------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(6);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL, 1);
  v_r := cerebro_aplicar_servicio(c.conv, 'recarga', 'cambiar', 'agent:cambiar_servicio', 'exec266-f');
  PERFORM pg_temp.a_chk('6', v_r, 'ninguna', 'deposito_bajo_minimo', false);
  PERFORM pg_temp.a_eq('6 message says what is missing', (position('faltan 1,200' in coalesce(v_r ->> 'mensaje', '')) > 0)::text, 'true');
  PERFORM pg_temp.a_eq('6 holder untouched', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');
  PERFORM pg_temp.a_eq('6 recipient untouched', pg_temp.a_vig(v_op), 'cuban_card:1');
  PERFORM pg_temp.a_eq('6 no audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_op), '0');

  -- ---- 7. Q8: a recarga holder with 6,200 becomes a card remesa when the customer changes its mind -----------------------------
  SELECT * INTO c FROM pg_temp.a_conv(7);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'recarga', NULL, 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'recarga', NULL, '55507001', 1);
  v_r := cerebro_aplicar_servicio(c.conv, 'cuban_card', 'cambiar', 'agent:cambiar_servicio', 'exec266-g');
  PERFORM pg_temp.a_chk('7', v_r, 'convertir', 'declarado', true);
  PERFORM pg_temp.a_eq('7 service', (SELECT service_type || '/' || coalesce(delivery_method, '-') FROM remittance_operations WHERE id = v_op), 'remesa/cuban_card');
  PERFORM pg_temp.a_eq('7 recarga number retired', (SELECT status FROM remittance_beneficiaries WHERE id = v_ben), 'reemplazado');
  PERFORM pg_temp.a_eq('7 retired listed', v_r #>> '{cambios,retirados}', jsonb_build_array(v_ben)::text);
  PERFORM pg_temp.a_eq('7 deposit still linked', (SELECT count(*)::text FROM remittance_operation_receipts WHERE operation_id = v_op), '1');

  -- ---- 8. a mixed group is untouched (changes go through repartir_envio) -----------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(8);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', 'clasica', 18200, true);
  v_dup := pg_temp.a_op(c, 'ready_to_transfer', 'recarga', NULL, 6200, false);
  UPDATE remittance_operations SET mixed_group_id = v_op WHERE id IN (v_op, v_dup);
  v_r := cerebro_aplicar_servicio(c.conv, 'recarga', 'cambiar', 'agent:cambiar_servicio', 'exec266-h');
  PERFORM pg_temp.a_chk('8', v_r, 'ninguna', 'grupo_mixto', false);
  PERFORM pg_temp.a_eq('8 services', (SELECT string_agg(service_type, ',' ORDER BY service_type) FROM remittance_operations WHERE conversation_id = c.conv), 'recarga,remesa');
  PERFORM pg_temp.a_eq('8 both open', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND status = 'ready_to_transfer'), '2');

  -- ---- 9. a human lock is untouched -------------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(9);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations
     SET admin_locked_fields = jsonb_build_object('service_type', jsonb_build_object('by', 'user:test266', 'at', now()))
   WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_r := cerebro_aplicar_servicio(c.conv, 'recarga', 'cambiar', 'agent:cambiar_servicio', 'exec266-i');
  PERFORM pg_temp.a_chk('9', v_r, 'ninguna', 'bloqueada', false);
  PERFORM pg_temp.a_eq('9 untouched', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');

  -- ---- 10. a human caller keeps the human audit action; a non-agent declaration is not stored -----------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(10);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55510001', 1, 1200, 'CUP', 'cuban_card');
  v_r := cerebro_aplicar_servicio(c.conv, NULL, NULL, 'user:ana');
  PERFORM pg_temp.a_chk('10 human', v_r, 'convertir', 'monto_precio_y_celular', true);
  PERFORM pg_temp.a_eq('10 human audit action', pg_temp.a_audit(v_op, 'service', 'human_correction', 'user:ana')::text, '1');
  PERFORM pg_temp.a_eq('10 human lock names the human', (SELECT admin_locked_fields #>> '{service_type,by}' FROM remittance_operations WHERE id = v_op), 'user:ana');
  PERFORM pg_temp.a_eq('10 no declaration stored for a human', (SELECT count(*)::text FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), '0');

  -- ---- 11. error path: the call is undone, the resolver's answer comes back with the sqlstate ---------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(11);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55511001', 1, 1200, 'CUP', 'cuban_card');
  CREATE TRIGGER a_boom BEFORE UPDATE OF service_type ON remittance_operations
    FOR EACH ROW WHEN (NEW.service_type = 'recarga') EXECUTE FUNCTION pg_temp.a_boom();
  v_r := cerebro_aplicar_servicio(c.conv);
  DROP TRIGGER a_boom ON remittance_operations;
  PERFORM pg_temp.a_chk('11', v_r, 'convertir', 'monto_precio_y_celular', false);
  PERFORM pg_temp.a_eq('11 sqlstate', v_r ->> 'sqlstate', 'XX999');
  PERFORM pg_temp.a_eq('11 cambios', v_r ->> 'cambios', '{}');
  PERFORM pg_temp.a_eq('11 still remesa', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');
  PERFORM pg_temp.a_eq('11 recipient intact', (SELECT beneficiary_type || '/' || status FROM remittance_beneficiaries WHERE id = v_ben), 'cuban_card/vigente');
  PERFORM pg_temp.a_eq('11 no audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_op), '0');
  PERFORM pg_temp.a_eq('11 guc origin', coalesce(current_setting('wacrm.origin', true), ''), '');
  PERFORM pg_temp.a_eq('11 guc actor', coalesce(current_setting('wacrm.actor', true), ''), '');
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM pg_temp.a_chk('11 retry', v_r, 'convertir', 'monto_precio_y_celular', true);

  -- ---- 12. no conversation, unknown conversation, invalid declared service ------------------------------------------------------
  v_r := cerebro_aplicar_servicio(NULL);
  PERFORM pg_temp.a_chk('12 null', v_r, 'ninguna', 'sin_conversacion', false);
  v_r := cerebro_aplicar_servicio(gen_random_uuid());
  PERFORM pg_temp.a_chk('12 unknown', v_r, 'ninguna', 'sin_cambio', false);
  SELECT * INTO c FROM pg_temp.a_conv(12);
  v_r := cerebro_aplicar_servicio(c.conv, 'remesa', 'cambiar', 'agent:cambiar_servicio');
  PERFORM pg_temp.a_chk('12 remesa is not a target', v_r, 'ninguna', 'servicio_invalido', false);
  PERFORM pg_temp.a_eq('12 invalid declaration not stored', (SELECT count(*)::text FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), '0');

  -- ---- 13. ACL and shape --------------------------------------------------------------------------------------------------------
  IF has_function_privilege('anon', 'public.cerebro_aplicar_servicio(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 13: anon can execute'; END IF;
  IF has_function_privilege('authenticated', 'public.cerebro_aplicar_servicio(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 13: authenticated can execute'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x WHERE p.proname = 'cerebro_aplicar_servicio' AND x.grantee = 0) THEN
    RAISE EXCEPTION 'case 13: PUBLIC can execute'; END IF;
  IF NOT has_function_privilege('service_role', 'public.cerebro_aplicar_servicio(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 13: service_role cannot execute'; END IF;
  IF (SELECT p.provolatile::text || p.prosecdef::text FROM pg_proc p WHERE p.proname = 'cerebro_aplicar_servicio') IS DISTINCT FROM 'vtrue' THEN
    RAISE EXCEPTION 'case 13: not VOLATILE SECURITY DEFINER'; END IF;
  -- the core keeps its live ACL (owner only)
  IF has_function_privilege('anon', 'public._cambiar_servicio_core(uuid,text,text,text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._cambiar_servicio_core(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 13: the core became callable'; END IF;

  -- ---- 14. an authenticated caller must belong to the conversation's account -----------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(14);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55514001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_chk('14 stranger', v_r, 'ninguna', 'no_autorizado', false);
  PERFORM pg_temp.a_eq('14 stranger changed nothing', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  v_r := cerebro_aplicar_servicio(c.conv);
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_chk('14 member', v_r, 'convertir', 'monto_precio_y_celular', true);

  -- ---- 15. the panel path (crm_cambiar_servicio) through the shared core -----------------------------------------------------------
  -- a recipient WITH a card is retired when the remesa becomes a recarga (unchanged behaviour)
  SELECT * INTO c FROM pg_temp.a_conv(15);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', c_card, '55515001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  PERFORM crm_cambiar_servicio(v_op, 'recarga');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('15 card recipient retired', pg_temp.a_vig(v_op) || '/' || (SELECT status FROM remittance_beneficiaries WHERE id = v_ben), 'none/reemplazado');
  -- a lone phone-only recipient is kept as a recarga number (re-typed, priced fields cleared)
  SELECT * INTO c FROM pg_temp.a_conv(16);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55516001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  v_r := crm_cambiar_servicio(v_op, 'recarga');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('15 phone-only kept', pg_temp.a_vig(v_op), 'recarga:1');
  PERFORM pg_temp.a_eq('15 same row', (SELECT status || '/' || phone || '/' || coalesce(amount::text, '-') FROM remittance_beneficiaries WHERE id = v_ben), 'vigente/55516001/-');
  PERFORM pg_temp.a_eq('15 panel counts', (v_r ->> 'retired_recipients') || '/' || (v_r ->> 'retyped_recipients'), '0/1');
  PERFORM pg_temp.a_eq('15 human audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service' AND action = 'human_correction'), '1');
  -- saldo keeps it too (stored as beneficiary_type recarga)
  SELECT * INTO c FROM pg_temp.a_conv(17);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55517001', 1, 1200, 'CUP', 'cuban_card');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  PERFORM crm_cambiar_servicio(v_op, 'saldo');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('15 saldo keeps it', (SELECT service_type FROM remittance_operations WHERE id = v_op) || '/' || pg_temp.a_vig(v_op), 'saldo/recarga:1');
  -- every phone-only recipient is a number of the recarga (a recarga may go to several numbers): all are kept
  SELECT * INTO c FROM pg_temp.a_conv(18);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55518001', 1);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55518002', 2);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  PERFORM crm_cambiar_servicio(v_op, 'recarga');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('15 two phones kept as numbers', pg_temp.a_vig(v_op), 'recarga:2');
  -- a lone phone-only recipient does not survive a change to a card rail (the target is not recarga / saldo)
  SELECT * INTO c FROM pg_temp.a_conv(19);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', 'cuban_card', 5200);
  v_ben := pg_temp.a_ben(v_op, 'cuban_card', NULL, '55519001', 1);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  PERFORM crm_cambiar_servicio(v_op, 'zelle');
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.a_eq('15 zelle retires the mobile', pg_temp.a_vig(v_op), 'none');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
