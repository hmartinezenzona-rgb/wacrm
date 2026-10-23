\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 265 (v2): cerebro_declarar_servicio + cerebro_resolver_servicio.
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT) or by hand as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- Synthetic fixtures only: contacts 'PRUEBA resolver N', phones 5990253xxxx, fake mobiles 5550xxxx, card 9999...
-- odd/tasks/service-resolution.md, REDESIGN 2026-10-22: the bot declares intent; the database only checks money, data
-- and state. The resolver never reads message words: no text parameter, no message is used by the cases below.
-- Cases (number = label in the failure message):
--   1  Katiuska 14:30: phone-only remesa, 6,200 receipt, no declaration, promo live -> convertir recarga monto_precio_y_celular
--   1b the same with a recarga word typed by the customer -> unchanged (words are not read)
--   2  Katiuska 14:32: declared recarga (cambiar and no intent) -> convertir declarado
--   3  card holder 5,000 + agregar recarga -> aparte; 4 card holder 13,000 + agregar recarga -> mixto (adicionales)
--   5  card holder 5,000 + cambiar recarga -> deposito_bajo_minimo, minimo 6,200, faltante, mensaje with both numbers
--   6  recarga holder with numbers + cambiar cuban_card with 6,200 -> convertir (owner Q8)
--   7  89f6df7e shape: Zelle deposit 83,200, a recarga word and a promo question typed -> sin_cambio, servicio zelle
--   8  declared row used when p_declarado is NULL; 9 latest declaration wins; p_declarado overrides the row
--   10 invalid service / intention refused; 11 declaration cleared by the trigger when the last open operation closes
--   12 mixed group -> grupo_mixto; 13 human lock -> bloqueada, bot lock -> convertir
--   14 completed operation ignored; 15 recarga without promo -> recarga_sin_promo
--   16 saldo and combo minimums (declared), visa (declared), rail declared on a remesa (zelle minimum)
--   17 lone empty remesa + declared recarga + p_monto; no holder + p_monto (new operation, below minimum, phone-only)
--   18 duplicates: empty recarga cancelled on convertir, empty remesa of the holder's own service is not
--   19 two deposits in two operations -> depositos_separados; two empty operations -> varias_operaciones
--   20 agregar with the holder already of that service -> sin_cambio; ready_to_transfer converts (Q6); incident refused
--   21 error path: fail open with version 2 and permitido false; 22 ACL, shape, table privileges and RLS
-- =====================================================================

CREATE FUNCTION pg_temp.a_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990253' || lpad(p_n::text, 4, '0'), 'PRUEBA resolver ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

-- An operation; p_receipt true = it holds a deposit (a receipt row), as registrar_deposito leaves it.
CREATE FUNCTION pg_temp.a_op(p_c record, p_status text, p_svc text, p_rail text, p_amt numeric, p_receipt boolean DEFAULT false) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, p_status, p_svc, p_rail, 'GYD', p_amt, clock_timestamp()) RETURNING id INTO v_op;
  IF p_receipt THEN
    INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, source)
    VALUES (v_op, p_c.conv, 'R265-' || substr(v_op::text, 1, 8), p_amt, 'GYD', 'bot');
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.a_msg(p_conv uuid, p_txt text) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (p_conv, 'customer', 'text', p_txt, clock_timestamp());
$f$;

CREATE FUNCTION pg_temp.a_zelle(p_conv uuid, p_cuenta text) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, zelle_cuenta, actualizado) VALUES (p_conv, p_cuenta, clock_timestamp())
  ON CONFLICT (conversation_id) DO UPDATE SET zelle_cuenta = EXCLUDED.zelle_cuenta, actualizado = EXCLUDED.actualizado;
$f$;

CREATE FUNCTION pg_temp.a_ben(p_op uuid, p_type text, p_card text, p_phone text, p_pos int DEFAULT 1) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (p_op, p_type, p_card, p_phone, p_pos, p_pos, 'test265', 'vigente');
$f$;

CREATE FUNCTION pg_temp.a_parcial(p_conv uuid, p_tarjeta text, p_celular text) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, tarjeta, celular, actualizado) VALUES (p_conv, p_tarjeta, p_celular, clock_timestamp())
  ON CONFLICT (conversation_id) DO UPDATE SET tarjeta = EXCLUDED.tarjeta, celular = EXCLUDED.celular, actualizado = EXCLUDED.actualizado;
$f$;

CREATE FUNCTION pg_temp.a_chk(p_label text, p_got jsonb, p_accion text, p_motivo text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got ->> 'accion' IS DISTINCT FROM p_accion OR p_got ->> 'motivo' IS DISTINCT FROM p_motivo THEN
    RAISE EXCEPTION 'case %: expected % / %, got %', p_label, p_accion, p_motivo, p_got - 'operaciones';
  END IF;
END $f$;

CREATE FUNCTION pg_temp.a_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

DO $$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
  c record; v_op uuid; v_op2 uuid; v_empty uuid; v_r jsonb; v_n int;
  v_usd numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric, NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000);
  v_cup numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_saldo numeric := cerebro_saldo_precio();
  c_card constant text := '9999000000000001';
BEGIN
  -- A promo running whose recarga price is 6,200 (min_cup 600); every other promo is out of the way.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT 265', 'https://assert.invalid/265', 'assert', md5('assert-265-vigente'), 'confirmada');
  IF (SELECT precio_gyd FROM cerebro_promo_vigente()) IS DISTINCT FROM 6200 THEN RAISE EXCEPTION 'fixture: promo price is not 6200'; END IF;

  -- ---- 1. Katiuska 14:30: phone-only remesa holding 6,200, no declaration, promo live -------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(1);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_parcial(c.conv, NULL, '55501001');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('1', v_r, 'convertir', 'monto_precio_y_celular');
  PERFORM pg_temp.a_eq('1 destino', v_r ->> 'destino_operacion', v_op::text);
  PERFORM pg_temp.a_eq('1 convertir_a', v_r ->> 'convertir_a', 'recarga');
  PERFORM pg_temp.a_eq('1 servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('1 en_curso', v_r ->> 'en_curso', 'remesa');
  PERFORM pg_temp.a_eq('1 permitido', v_r ->> 'permitido', 'true');
  PERFORM pg_temp.a_eq('1 cancelar', v_r ->> 'cancelar', '[]');
  PERFORM pg_temp.a_eq('1 version', v_r ->> 'version', '2');
  PERFORM pg_temp.a_eq('1 evidencia.solo_celular', v_r #>> '{evidencia,solo_celular}', 'true');
  PERFORM pg_temp.a_eq('1 evidencia.monto_igual_precio', v_r #>> '{evidencia,monto_igual_precio}', 'true');
  PERFORM pg_temp.a_eq('1 still remesa (never writes)', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');
  -- 1c (parent review) the REAL 1232671b shape: no rail on the operation, the system saved the number as a cuban_card
  --    recipient WITHOUT a card (notes_parse). A card-typed recipient with no card number is still phone-only.
  SELECT * INTO c FROM pg_temp.a_conv(101);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', NULL, '55501011');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('1c real shape', v_r, 'convertir', 'monto_precio_y_celular');
  -- 1b the customer types the recarga word: the resolver does not read words, the result stays the same
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('1b words ignored', v_r, 'convertir', 'monto_precio_y_celular');

  -- ---- 2. Katiuska 14:32: the agent declared recarga ------------------------------------------------------------------------
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('2 declared cambiar', v_r, 'convertir', 'declarado');
  PERFORM pg_temp.a_eq('2 destino', v_r ->> 'destino_operacion', v_op::text);
  PERFORM pg_temp.a_eq('2 convertir_a', v_r ->> 'convertir_a', 'recarga');
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', NULL);
  PERFORM pg_temp.a_chk('2 declared, intent NULL = cambiar', v_r, 'convertir', 'declarado');

  -- ---- 3. card holder 5,000 + agregar recarga: the deposit does not cover both -> a separate operation ----------------------
  SELECT * INTO c FROM pg_temp.a_conv(2);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', v_cup, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'agregar');
  PERFORM pg_temp.a_chk('3 aparte', v_r, 'aparte', 'adicional_aparte');
  PERFORM pg_temp.a_eq('3 servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('3 holder untouched', v_r ->> 'destino_operacion', NULL);
  PERFORM pg_temp.a_eq('3 minimo', v_r ->> 'minimo_gyd', '6200');
  PERFORM pg_temp.a_eq('3 permitido', v_r ->> 'permitido', 'true');
  PERFORM pg_temp.a_eq('3 holder still cuban_card', (SELECT service_type || '/' || delivery_method FROM remittance_operations WHERE id = v_op), 'remesa/cuban_card');

  -- ---- 4. card holder 13,000 + agregar recarga: one deposit covers both -> mixto -------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(3);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', v_cup + 6200 + 2000, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'agregar');
  PERFORM pg_temp.a_chk('4 mixto', v_r, 'mixto', 'deposito_cubre_ambos');
  PERFORM pg_temp.a_eq('4 servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('4 destino', v_r ->> 'destino_operacion', v_op::text);
  PERFORM pg_temp.a_eq('4 adicionales', v_r #>> '{adicionales,0,servicio}', 'recarga');
  PERFORM pg_temp.a_eq('4 adicionales monto', v_r #>> '{adicionales,0,monto}', '6200');
  PERFORM pg_temp.a_eq('4 cancelar', v_r ->> 'cancelar', '[]');

  -- ---- 5. card holder 5,000 + cambiar recarga: below the recarga price -> no change, with the numbers ----------------------
  SELECT * INTO c FROM pg_temp.a_conv(4);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', v_cup, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('5 below minimum', v_r, 'ninguna', 'deposito_bajo_minimo');
  PERFORM pg_temp.a_eq('5 minimo', v_r ->> 'minimo_gyd', '6200');
  PERFORM pg_temp.a_eq('5 faltante', v_r ->> 'faltante_gyd', (6200 - v_cup)::text);
  PERFORM pg_temp.a_eq('5 mensaje has minimo', ((v_r ->> 'mensaje') LIKE '%6,200 GYD%')::text, 'true');
  PERFORM pg_temp.a_eq('5 mensaje has faltante', ((v_r ->> 'mensaje') LIKE '%' || to_char(6200 - v_cup, 'FM999,999,999') || ' GYD%')::text, 'true');
  PERFORM pg_temp.a_eq('5 permitido', v_r ->> 'permitido', 'false');
  PERFORM pg_temp.a_eq('5 holder kept', v_r ->> 'destino_operacion', NULL);

  -- ---- 6. Q8: a recarga holder with numbers, the customer changes to a CUP card with 6,200 -> convertir -------------------------
  SELECT * INTO c FROM pg_temp.a_conv(5);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'recarga', NULL, 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'recarga', NULL, '55501005');
  v_r := cerebro_resolver_servicio(c.conv, 'cuban_card', 'cambiar');
  PERFORM pg_temp.a_chk('6 Q8', v_r, 'convertir', 'declarado');
  PERFORM pg_temp.a_eq('6 convertir_a', v_r ->> 'convertir_a', 'cuban_card');
  PERFORM pg_temp.a_eq('6 en_curso', v_r ->> 'en_curso', 'recarga');
  PERFORM pg_temp.a_eq('6 destino', v_r ->> 'destino_operacion', v_op::text);

  -- ---- 7. 89f6df7e: Zelle deposit 83,200; recarga words and a promo question typed; no declaration -> nothing changes -----
  SELECT * INTO c FROM pg_temp.a_conv(6);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'zelle', 83200, true);
  PERFORM pg_temp.a_msg(c.conv, 'es por zelle, tienen recargas?');
  PERFORM pg_temp.a_msg(c.conv, 'quiero una recarga');
  PERFORM pg_temp.a_zelle(c.conv, 'cliente@example.invalid');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('7 zelle, words ignored', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('7 servicio', v_r ->> 'servicio', 'zelle');
  PERFORM pg_temp.a_eq('7 en_curso', v_r ->> 'en_curso', 'zelle');
  -- (279) sin_cambio now carries a plain-Spanish sentence (it used to be NULL): the agent always gets something to say.
  PERFORM pg_temp.a_eq('7 mensaje', v_r ->> 'mensaje', 'La operación ya es Zelle: no hay nada que cambiar.');

  -- ---- 8. declared row used when p_declarado is NULL -------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(7);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  v_r := cerebro_declarar_servicio(c.conv, 'recarga', 'agente');
  PERFORM pg_temp.a_eq('8 declarar ok', v_r ->> 'ok', 'true');
  PERFORM pg_temp.a_eq('8 declarar servicio', v_r ->> 'servicio', 'recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('8 row used', v_r, 'convertir', 'declarado');
  PERFORM pg_temp.a_eq('8 row convertir_a', v_r ->> 'convertir_a', 'recarga');

  -- ---- 9. latest declaration wins; p_declarado overrides the stored row --------------------------------------------------------
  v_r := cerebro_declarar_servicio(c.conv, 'cuban_card', 'agente');
  PERFORM pg_temp.a_eq('9 latest declared', v_r ->> 'servicio', 'cuban_card');
  PERFORM pg_temp.a_eq('9 one row', (SELECT count(*)::text FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), '1');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_eq('9 latest used', v_r ->> 'convertir_a', 'cuban_card');
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_eq('9 p_declarado overrides the row', v_r ->> 'convertir_a', 'recarga');

  -- ---- 10. invalid service / intention are refused ----------------------------------------------------------------------------
  v_r := cerebro_declarar_servicio(c.conv, 'cup', 'agente');
  PERFORM pg_temp.a_eq('10 invalid declaration', v_r ->> 'motivo', 'servicio_invalido');
  PERFORM pg_temp.a_eq('10 invalid keeps the row', (SELECT servicio FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), 'cuban_card');
  v_r := cerebro_resolver_servicio(c.conv, 'cup', 'cambiar');
  PERFORM pg_temp.a_chk('10 invalid p_declarado', v_r, 'ninguna', 'servicio_invalido');
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'quitar');
  PERFORM pg_temp.a_chk('10 invalid intention', v_r, 'ninguna', 'intencion_invalida');

  -- ---- 11. the declaration is cleared when the last open operation closes (trigger) ----------------------------------------------
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  PERFORM pg_temp.a_eq('11 cleared with the last open operation', (SELECT count(*)::text FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), '0');
  -- two open operations: the declaration stays until the last one closes
  SELECT * INTO c FROM pg_temp.a_conv(8);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  v_empty := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  PERFORM cerebro_declarar_servicio(c.conv, 'recarga', 'agente');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM pg_temp.a_eq('11 kept while another operation is open', (SELECT count(*)::text FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), '1');
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_empty;
  PERFORM set_config('wacrm.origin', '', true);
  PERFORM pg_temp.a_eq('11 cleared when the last one cancels', (SELECT count(*)::text FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), '0');

  -- ---- 12. a mixed group is changed only through repartir_envio ----------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(9);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', 'clasica', 18200, true);
  v_op2 := pg_temp.a_op(c, 'ready_to_transfer', 'recarga', NULL, 6200, false);
  UPDATE remittance_operations SET mixed_group_id = v_op WHERE id IN (v_op, v_op2);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('12 mixed group', v_r, 'ninguna', 'grupo_mixto');
  PERFORM pg_temp.a_eq('12 grupo', v_r ->> 'grupo_mixto', v_op::text);

  -- ---- 13. a human lock excludes; a lock the bot left does not ------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(10);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations
     SET admin_locked_fields = jsonb_build_object('service_type', jsonb_build_object('by', 'user:test265', 'at', now()))
   WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('13 human lock', v_r, 'ninguna', 'bloqueada');
  UPDATE remittance_operations
     SET admin_locked_fields = jsonb_build_object('service_type', jsonb_build_object('by', 'automation:cerebro_cambiar_servicio', 'at', now()))
   WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('13 bot lock', v_r, 'convertir', 'declarado');
  PERFORM set_config('wacrm.origin', '', true);

  -- ---- 14. a completed operation is never converted ------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(11);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', 'cuban_card', 6200, true);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  IF (SELECT status FROM remittance_operations WHERE id = v_op) <> 'completed' THEN RAISE EXCEPTION 'fixture: could not complete'; END IF;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('14 completed ignored', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('14 operaciones', jsonb_array_length(v_r -> 'operaciones')::text, '0');
  PERFORM pg_temp.a_eq('14 en_curso', v_r ->> 'en_curso', NULL);

  -- ---- 15. recarga without a live or announced promo ----------------------------------------------------------------------------
  UPDATE promo_etecsa SET estado = 'descartada' WHERE huella = md5('assert-265-vigente');
  SELECT * INTO c FROM pg_temp.a_conv(12);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('15 no promo, holder', v_r, 'ninguna', 'recarga_sin_promo');
  SELECT * INTO c FROM pg_temp.a_conv(13);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('15 no promo, no holder', v_r, 'ninguna', 'recarga_sin_promo');
  -- saldo and visa and combo do not depend on the promo
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, v_saldo, true);
  v_r := cerebro_resolver_servicio(c.conv, 'saldo', 'cambiar');
  PERFORM pg_temp.a_chk('15 saldo without promo', v_r, 'convertir', 'declarado');
  PERFORM pg_temp.a_eq('15 saldo convertir_a', v_r ->> 'convertir_a', 'saldo');
  UPDATE promo_etecsa SET estado = 'confirmada' WHERE huella = md5('assert-265-vigente');

  -- ---- 16. minimums of the declared services -------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(14);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 25000, true);
  v_r := cerebro_resolver_servicio(c.conv, 'combo', 'cambiar');
  PERFORM pg_temp.a_chk('16 combo, 25,000 holder', v_r, 'convertir', 'declarado');
  PERFORM pg_temp.a_eq('16 combo convertir_a', v_r ->> 'convertir_a', 'combo');
  UPDATE remittance_operation_receipts SET amount = v_cup WHERE operation_id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = v_cup WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv, 'combo', 'cambiar');
  PERFORM pg_temp.a_chk('16 combo below minimum', v_r, 'ninguna', 'deposito_bajo_minimo');
  PERFORM pg_temp.a_eq('16 combo minimo', v_r ->> 'minimo_gyd', '25000');
  PERFORM pg_temp.a_eq('16 combo faltante', v_r ->> 'faltante_gyd', (25000 - v_cup)::text);
  SELECT * INTO c FROM pg_temp.a_conv(15);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 5000, true);
  v_r := cerebro_resolver_servicio(c.conv, 'visa', 'cambiar');
  PERFORM pg_temp.a_chk('16 visa', v_r, 'convertir', 'declarado');
  PERFORM pg_temp.a_eq('16 visa convertir_a', v_r ->> 'convertir_a', 'visa');
  -- a rail declared on a card remesa: the Zelle minimum applies
  SELECT * INTO c FROM pg_temp.a_conv(16);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', v_cup, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  v_r := cerebro_resolver_servicio(c.conv, 'zelle', 'cambiar');
  PERFORM pg_temp.a_chk('16 zelle rail below the USD minimum', v_r, 'ninguna', 'deposito_bajo_minimo');
  PERFORM pg_temp.a_eq('16 zelle minimo', v_r ->> 'minimo_gyd', v_usd::text);
  PERFORM pg_temp.a_eq('16 zelle faltante', v_r ->> 'faltante_gyd', (v_usd - v_cup)::text);
  PERFORM pg_temp.a_eq('16 zelle servicio stays', v_r ->> 'servicio', 'cuban_card');

  -- ---- 17. no holder: p_monto only; the lone empty remesa is the subject ----------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(17);
  PERFORM pg_temp.a_parcial(c.conv, NULL, '55501017');
  v_r := cerebro_resolver_servicio(c.conv, NULL, NULL, 6200);
  PERFORM pg_temp.a_chk('17 new operation, phone-only, price multiple', v_r, 'ninguna', 'monto_precio_y_celular');
  PERFORM pg_temp.a_eq('17 new servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('17 fuente', v_r #>> '{evidencia,fuente}', 'parametro');
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar', 5000);
  PERFORM pg_temp.a_chk('17 new operation below minimum', v_r, 'ninguna', 'deposito_bajo_minimo');
  PERFORM pg_temp.a_eq('17 faltante', v_r ->> 'faltante_gyd', '1200');
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar', 6200);
  PERFORM pg_temp.a_chk('17 new operation, declared', v_r, 'ninguna', 'nueva_operacion');
  PERFORM pg_temp.a_eq('17 new servicio declared', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('17 new permitido', v_r ->> 'permitido', 'true');
  -- an empty remesa waiting for its deposit becomes the recarga when the 6,200 arrives
  SELECT * INTO c FROM pg_temp.a_conv(18);
  v_empty := pg_temp.a_op(c, 'collecting_information', 'remesa', NULL, 0, false);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('17 lone empty, no money yet', v_r, 'ninguna', 'deposito_bajo_minimo');
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar', 6200);
  PERFORM pg_temp.a_chk('17 lone empty, 6,200 arrives', v_r, 'convertir', 'declarado');
  PERFORM pg_temp.a_eq('17 lone empty destino', v_r ->> 'destino_operacion', v_empty::text);

  -- ---- 18. duplicates: the empty recarga next to a remesa holder is cancelled on convertir; the same service is not -----------
  SELECT * INTO c FROM pg_temp.a_conv(19);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', NULL, 6200, true);
  v_empty := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  PERFORM pg_temp.a_ben(v_empty, 'recarga', NULL, '55501019');
  v_op2 := pg_temp.a_op(c, 'collecting_information', 'remesa', NULL, 0, false);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('18 convertir', v_r, 'convertir', 'declarado');
  PERFORM pg_temp.a_eq('18 cancelar only the other service', v_r ->> 'cancelar', jsonb_build_array(v_empty)::text);

  -- ---- 19. one deposit per operation is never a mixed send; empty operations without deposit are ambiguous ---------------------
  SELECT * INTO c FROM pg_temp.a_conv(20);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  v_op2 := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'agregar');
  PERFORM pg_temp.a_chk('19 separate deposits', v_r, 'ninguna', 'depositos_separados');
  PERFORM pg_temp.a_eq('19 operaciones', jsonb_array_length(v_r -> 'operaciones')::text, '2');
  PERFORM pg_temp.a_eq('19 cancelar', v_r ->> 'cancelar', '[]');
  SELECT * INTO c FROM pg_temp.a_conv(21);
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', NULL, 0, false);
  v_op2 := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('19 two empty operations', v_r, 'ninguna', 'varias_operaciones');

  -- ---- 20. agregar with the holder already of that service; ready_to_transfer converts; incident refused -------------------
  SELECT * INTO c FROM pg_temp.a_conv(22);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'recarga', NULL, 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'recarga', NULL, '55501022');
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'agregar');
  PERFORM pg_temp.a_chk('20 already of that service', v_r, 'ninguna', 'sin_cambio');
  SELECT * INTO c FROM pg_temp.a_conv(23);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', NULL, 6200, true);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('20 ready_to_transfer converts (Q6)', v_r, 'convertir', 'declarado');
  SELECT * INTO c FROM pg_temp.a_conv(24);
  v_op := pg_temp.a_op(c, 'incident', 'remesa', NULL, 6200, true);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('20 incident', v_r, 'ninguna', 'estado_no_permite');
  UPDATE remittance_operations SET status = 'transferring' WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('20 transferring', v_r, 'ninguna', 'estado_no_permite');

  -- ---- 21. error path: fail open ------------------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(25);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  UPDATE cerebro_config SET valor = 'not-a-number' WHERE clave = 'minimo_gyd_cup';
  v_r := cerebro_resolver_servicio(c.conv, 'recarga', 'cambiar');
  PERFORM pg_temp.a_chk('21 error', v_r, 'ninguna', 'error');
  PERFORM pg_temp.a_eq('21 version', v_r ->> 'version', '2');
  PERFORM pg_temp.a_eq('21 permitido', v_r ->> 'permitido', 'false');
  PERFORM pg_temp.a_eq('21 cancelar', v_r ->> 'cancelar', '[]');
  PERFORM pg_temp.a_eq('21 operaciones', v_r ->> 'operaciones', '[]');
  UPDATE cerebro_config SET valor = v_cup::text WHERE clave = 'minimo_gyd_cup';

  -- ---- 22. ACL, shape and table privileges -----------------------------------------------------------------------------------------
  IF has_function_privilege('anon', 'public.cerebro_resolver_servicio(uuid,text,text,numeric,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 22: anon can execute the resolver'; END IF;
  IF has_function_privilege('anon', 'public.cerebro_declarar_servicio(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 22: anon can execute the declaration'; END IF;
  IF NOT has_function_privilege('service_role', 'public.cerebro_resolver_servicio(uuid,text,text,numeric,timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cerebro_resolver_servicio(uuid,text,text,numeric,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 22: authenticated / service_role cannot execute the resolver'; END IF;
  -- (parent review) only the bot (service role) declares intents: a panel user must not write one for any conversation.
  IF NOT has_function_privilege('service_role', 'public.cerebro_declarar_servicio(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 22: service_role cannot execute the declaration'; END IF;
  IF has_function_privilege('authenticated', 'public.cerebro_declarar_servicio(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 22: authenticated can execute the declaration'; END IF;
  IF (SELECT p.provolatile::text || p.prosecdef::text FROM pg_proc p WHERE p.proname = 'cerebro_resolver_servicio') IS DISTINCT FROM 'strue' THEN
    RAISE EXCEPTION 'case 22: resolver is not STABLE SECURITY DEFINER'; END IF;
  IF (SELECT p.provolatile::text || p.prosecdef::text FROM pg_proc p WHERE p.proname = 'cerebro_declarar_servicio') IS DISTINCT FROM 'vtrue' THEN
    RAISE EXCEPTION 'case 22: declaration is not VOLATILE SECURITY DEFINER'; END IF;
  IF has_table_privilege('authenticated', 'public.cerebro_servicio_declarado', 'SELECT')
     OR has_table_privilege('anon', 'public.cerebro_servicio_declarado', 'SELECT') THEN
    RAISE EXCEPTION 'case 22: the declaration table is readable by authenticated or anon'; END IF;
  IF NOT has_table_privilege('service_role', 'public.cerebro_servicio_declarado', 'SELECT') THEN
    RAISE EXCEPTION 'case 22: service_role cannot read the declaration table'; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.cerebro_servicio_declarado'::regclass) THEN
    RAISE EXCEPTION 'case 22: RLS is not enabled on the declaration table'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
