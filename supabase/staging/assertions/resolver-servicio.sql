\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 265 (cerebro_resolver_servicio: one read-only answer to "which service is this operation").
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT) or by hand as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- Synthetic fixtures only: contacts 'PRUEBA resolver N', phones 5990253xxxx, fake mobiles 5550xxxx, no customer data.
-- odd/tasks/service-resolution.md (S2) with the owner answers Q1, Q3-Q7 and the 2026-10-22 rule "the customer can always
-- change the service of the holder; coverage decides correction vs addition".
-- Cases (number = label in the failure message):
--   1  1232671b@14:30 shape (6,200 receipt + phone-only, no words, promo)      -> convertir recarga monto_precio_y_celular
--   2  1232671b@14:32 ("es para una recarga")                                   -> convertir recarga palabras
--   3  legacy duplicate (+ empty recarga) and ready_to_transfer (Q6)           -> convertir + cancelar [empty]
--   4  d86574ab (12,400 = 2 recargas) / 5 d415e347 (saldo words, no promo)      -> convertir recarga / saldo
--   6  mixed group (f8b7779c)                                                   -> ninguna grupo_mixto
--   7  two operations, separate deposits (bf547067)                             -> ninguna depositos_separados, no alerta
--   8  89f6df7e: promo question then Zelle account -> never recarga; a later "y tambien una recarga" -> adicional / convertir
--   9  card + recarga word (covers both / only the recarga / below minimum)     -> adicional / convertir / bajo_minimo
--   10 plain remesa; 11 plain recarga with word / open recarga; 12 no promo
--   13 combo words (+ below minimum); 14 visa: bare word vs explicit phrase
--   15 human lock vs bot lock; 16 completed operation; 17 error path; 18 ACL
--   19 declared service and p_monto without operation
--   20 owner rule: recarga -> card / adicional / Zelle below minimum; 21 reverse safety net; 22 ambiguous words
--   23 incident; 24 negated word; 25 latest signal wins (change of mind); 26 price/promo questions are not requests
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

-- A customer text dated in the past (before the operation exists): p_ago minutes ago.
CREATE FUNCTION pg_temp.a_msg_ago(p_conv uuid, p_txt text, p_ago int) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (p_conv, 'customer', 'text', p_txt, clock_timestamp() - make_interval(mins => p_ago));
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
  c record; v_op uuid; v_op2 uuid; v_empty uuid; v_r jsonb;
  v_usd numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric, NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000);
  v_cup numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_rec numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200);
  c_card constant text := '9999000000000001';
BEGIN
  -- A promo running whose recarga price is 6,200 (min_cup 600); every other promo is out of the way.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT 265', 'https://assert.invalid/265', 'assert', md5('assert-265-vigente'), 'confirmada');
  IF (SELECT precio_gyd FROM cerebro_promo_vigente()) IS DISTINCT FROM 6200 THEN RAISE EXCEPTION 'fixture: promo price is not 6200'; END IF;

  -- ---- 1. 1232671b@14:30: a 6,200 receipt + a Cuban mobile, no words ---------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(1);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_parcial(c.conv, NULL, '55501001');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('1', v_r, 'convertir', 'monto_precio_y_celular');
  PERFORM pg_temp.a_eq('1 destino', v_r ->> 'destino_operacion', v_op::text);
  PERFORM pg_temp.a_eq('1 convertir_a', v_r ->> 'convertir_a', 'recarga');
  PERFORM pg_temp.a_eq('1 servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('1 en_curso', v_r ->> 'en_curso', 'remesa');
  PERFORM pg_temp.a_eq('1 confianza', v_r ->> 'confianza', 'alta');
  PERFORM pg_temp.a_eq('1 via_actual', v_r ->> 'via_actual', NULL);
  PERFORM pg_temp.a_eq('1 cancelar', v_r ->> 'cancelar', '[]');
  PERFORM pg_temp.a_eq('1 alerta', v_r ->> 'alerta', NULL);
  PERFORM pg_temp.a_eq('1 version', v_r ->> 'version', '1');
  PERFORM pg_temp.a_eq('1 evidencia.precio', v_r #>> '{evidencia,monto_es_precio_recarga}', 'true');
  PERFORM pg_temp.a_eq('1 evidencia.solo', v_r #>> '{evidencia,celular_solo}', 'true');
  -- it never writes
  PERFORM pg_temp.a_eq('1 still remesa', (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');

  -- ---- 2. 1232671b@14:32: "es para una recarga" -----------------------------------------------------------------------
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('2', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('2 destino', v_r ->> 'destino_operacion', v_op::text);
  PERFORM pg_temp.a_eq('2 palabras', v_r #>> '{evidencia,palabras,recarga}', 'true');
  -- the same through p_texto (the message not stored yet)
  SELECT * INTO c FROM pg_temp.a_conv(2);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  v_r := cerebro_resolver_servicio(c.conv, NULL, 'es para una recarga');
  PERFORM pg_temp.a_chk('2 p_texto', v_r, 'convertir', 'palabras');

  -- ---- 3. legacy duplicate: the empty recarga the agent opened next to the holder; Q6 verified deposit ---------------------
  SELECT * INTO c FROM pg_temp.a_conv(3);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', NULL, 6200, true);
  v_empty := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  PERFORM pg_temp.a_ben(v_empty, 'recarga', NULL, '55501003');
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('3', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('3 destino', v_r ->> 'destino_operacion', v_op::text);
  PERFORM pg_temp.a_eq('3 cancelar', v_r ->> 'cancelar', jsonb_build_array(v_empty)::text);
  PERFORM pg_temp.a_eq('3 cancelar_motivo', v_r ->> 'cancelar_motivo', 'duplicado_vacio');
  PERFORM pg_temp.a_eq('3 alerta', v_r ->> 'alerta', NULL);
  -- the holder is never listed as its own duplicate; an empty operation of the SAME service as the holder is not either
  v_op2 := pg_temp.a_op(c, 'collecting_information', 'remesa', NULL, 0, false);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_eq('3 cancelar only other service', v_r ->> 'cancelar', jsonb_build_array(v_empty)::text);
  -- without the conversion (no words, no phone-only evidence) nothing is cancelled
  SELECT * INTO c FROM pg_temp.a_conv(4);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  v_empty := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('3 no conversion', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('3 no conversion cancelar', v_r ->> 'cancelar', '[]');

  -- ---- 4. d86574ab: a remesa deposit of 2 recargas (12,400) and the word -----------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(5);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 12400, true);
  PERFORM pg_temp.a_msg(c.conv, 'quiero recarga para dos numeros');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('4', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('4 convertir_a', v_r ->> 'convertir_a', 'recarga');

  -- ---- 5. d415e347: saldo words ("recarga de saldo movil" is a saldo message, not a recarga one); saldo needs no promo --------
  UPDATE promo_etecsa SET estado = 'descartada' WHERE huella = md5('assert-265-vigente');
  SELECT * INTO c FROM pg_temp.a_conv(6);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 5000, true);
  PERFORM pg_temp.a_msg(c.conv, 'quiero una recarga de saldo movil');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('5', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('5 convertir_a', v_r ->> 'convertir_a', 'saldo');
  PERFORM pg_temp.a_eq('5 recarga flag', v_r #>> '{evidencia,palabras,recarga}', 'false');
  PERFORM pg_temp.a_eq('5 saldo flag', v_r #>> '{evidencia,palabras,saldo}', 'true');
  UPDATE promo_etecsa SET estado = 'confirmada' WHERE huella = md5('assert-265-vigente');

  -- ---- 6. f8b7779c: a mixed group is changed only through repartir_envio --------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(7);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', 'clasica', 18200, true);
  v_op2 := pg_temp.a_op(c, 'ready_to_transfer', 'recarga', NULL, 6200, false);
  UPDATE remittance_operations SET mixed_group_id = v_op WHERE id IN (v_op, v_op2);
  PERFORM pg_temp.a_msg(c.conv, 'clasica y una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('6', v_r, 'ninguna', 'grupo_mixto');
  PERFORM pg_temp.a_eq('6 grupo', v_r ->> 'grupo_mixto', v_op::text);

  -- ---- 7. bf547067: two operations paid by separate deposits are never additions of each other -----------------------------
  SELECT * INTO c FROM pg_temp.a_conv(8);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  v_op2 := pg_temp.a_op(c, 'deposit_verification', 'combo', NULL, 25000, true);
  PERFORM pg_temp.a_msg(c.conv, 'quiero un combo tambien');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('7', v_r, 'ninguna', 'depositos_separados');
  PERFORM pg_temp.a_eq('7 alerta', v_r ->> 'alerta', NULL);
  PERFORM pg_temp.a_eq('7 cancelar', v_r ->> 'cancelar', '[]');
  PERFORM pg_temp.a_eq('7 operaciones', jsonb_array_length(v_r -> 'operaciones')::text, '2');

  -- ---- 8. 89f6df7e (2026-10-04 bug): the customer only ASKED about a recharge promo, later paid a Zelle with its account -----------
  -- 8a a question about the promo inside the window is not a request (with and without a promo)
  SELECT * INTO c FROM pg_temp.a_conv(9);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'zelle', 83200, true);
  PERFORM pg_temp.a_msg(c.conv, 'es por zelle, tienen recargas?');
  PERFORM pg_temp.a_msg(c.conv, 'cuanto es la recarga?');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('8a', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('8a servicio', v_r ->> 'servicio', 'zelle');
  PERFORM pg_temp.a_eq('8a via_actual', v_r ->> 'via_actual', 'zelle');
  PERFORM pg_temp.a_eq('8a activas', v_r #>> '{evidencia,activas}', '[]');
  UPDATE promo_etecsa SET estado = 'descartada' WHERE huella = md5('assert-265-vigente');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('8a no promo', v_r, 'ninguna', 'sin_cambio');
  UPDATE promo_etecsa SET estado = 'confirmada' WHERE huella = md5('assert-265-vigente');
  -- 8b the exact shape: the question 24 min BEFORE the deposit (outside the holder's window), then the Zelle account
  SELECT * INTO c FROM pg_temp.a_conv(32);
  PERFORM pg_temp.a_msg_ago(c.conv, 'Tiene promocion de recarga de telefono', 24);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'zelle', 83200, true);
  PERFORM pg_temp.a_zelle(c.conv, 'cliente@example.invalid');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('8b', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('8b servicio', v_r ->> 'servicio', 'zelle');
  -- 8b2 even a STATEMENT ("quiero una recarga") followed later by the Zelle account is superseded
  SELECT * INTO c FROM pg_temp.a_conv(33);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'zelle', 83200, true);
  PERFORM pg_temp.a_msg(c.conv, 'quiero una recarga');
  PERFORM pg_temp.a_zelle(c.conv, 'cliente@example.invalid');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('8b2 superseded', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('8b2 servicio', v_r ->> 'servicio', 'zelle');
  PERFORM pg_temp.a_eq('8b2 palabras raw', v_r #>> '{evidencia,palabras,recarga}', 'true');
  PERFORM pg_temp.a_eq('8b2 activas', v_r #>> '{evidencia,activas}', '[]');
  -- 8c the customer LATER writes "y tambien una recarga al <mobile>": both requested after the Zelle data -> a mixed send
  PERFORM pg_temp.a_msg(c.conv, 'y tambien una recarga al 55501033');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('8c', v_r, 'adicional', 'deposito_cubre_ambos');
  PERFORM pg_temp.a_eq('8c servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('8c via_actual', v_r ->> 'via_actual', 'zelle');
  -- 8d same, but the deposit covers only the recarga request (13,100 pays Zelle, not Zelle + 6,200): the newest request wins
  UPDATE remittance_operation_receipts SET amount = v_usd + 100 WHERE operation_id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = v_usd + 100 WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('8d', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('8d convertir_a', v_r ->> 'convertir_a', 'recarga');
  -- 8e a NEW operation (no holder yet): question, Zelle account typed, 83,200 about to be registered -> servicio zelle
  SELECT * INTO c FROM pg_temp.a_conv(34);
  PERFORM pg_temp.a_msg(c.conv, 'Tiene promocion de recarga de telefono?');
  PERFORM pg_temp.a_zelle(c.conv, 'cliente@example.invalid');
  v_r := cerebro_resolver_servicio(c.conv, NULL, NULL, 83200);
  PERFORM pg_temp.a_chk('8e', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('8e servicio', v_r ->> 'servicio', 'zelle');
  -- 8e2 the same with a recarga STATEMENT before the Zelle account: superseded
  SELECT * INTO c FROM pg_temp.a_conv(35);
  PERFORM pg_temp.a_msg(c.conv, 'quiero una recarga');
  PERFORM pg_temp.a_zelle(c.conv, 'cliente@example.invalid');
  v_r := cerebro_resolver_servicio(c.conv, NULL, NULL, 83200);
  PERFORM pg_temp.a_chk('8e2', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('8e2 servicio', v_r ->> 'servicio', 'zelle');

  -- ---- 9. a card + a recarga word on the SAME deposit (Q4/Q5) --------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(10);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', v_cup + 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  PERFORM pg_temp.a_msg(c.conv, 'y ademas una recarga');
  v_empty := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('9 covers both', v_r, 'adicional', 'deposito_cubre_ambos');
  PERFORM pg_temp.a_eq('9 servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('9 via_actual', v_r ->> 'via_actual', 'cuban_card');
  PERFORM pg_temp.a_eq('9 adicional goes to the empty recarga', v_r ->> 'destino_operacion', v_empty::text);
  PERFORM pg_temp.a_eq('9 adicional cancels nothing', v_r ->> 'cancelar', '[]');
  UPDATE remittance_operation_receipts SET amount = 6200 WHERE operation_id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = 6200 WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('9 covers only the recarga (card holder converted)', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('9 convertir_a', v_r ->> 'convertir_a', 'recarga');
  PERFORM pg_temp.a_eq('9 destino', v_r ->> 'destino_operacion', v_op::text);
  -- the empty recarga is the duplicate of the converted holder
  PERFORM pg_temp.a_eq('9 cancelar', v_r ->> 'cancelar', jsonb_build_array(v_empty)::text);
  UPDATE remittance_operation_receipts SET amount = 4000 WHERE operation_id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = 4000 WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('9 below the recarga price', v_r, 'ninguna', 'deposito_bajo_minimo');
  PERFORM pg_temp.a_eq('9 minimo is the fixed recarga price', v_r ->> 'minimo_gyd', '6200');
  PERFORM pg_temp.a_eq('9 faltante', v_r ->> 'faltante_gyd', '2200');
  -- a deposit between the old 5,200 minimum and the 6,200 price no longer converts a recarga
  UPDATE remittance_operation_receipts SET amount = v_rec WHERE operation_id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = v_rec WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('9 5,200 is not 6,200', v_r, 'ninguna', 'deposito_bajo_minimo');
  PERFORM pg_temp.a_eq('9 servicio_minimo', v_r ->> 'servicio_minimo', 'recarga');

  -- ---- 10. a plain remesa --------------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(11);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('10', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('10 servicio', v_r ->> 'servicio', 'cuban_card');
  PERFORM pg_temp.a_eq('10 en_curso', v_r ->> 'en_curso', 'remesa');
  PERFORM pg_temp.a_eq('10 via_actual', v_r ->> 'via_actual', 'cuban_card');
  PERFORM pg_temp.a_eq('10 pregunta', v_r ->> 'pregunta', NULL);

  -- ---- 11. a plain recarga: the word with no operation yet; an open recarga stays -------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(12);
  PERFORM pg_temp.a_msg(c.conv, 'quiero hacer una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('11 new', v_r, 'ninguna', 'palabras');
  PERFORM pg_temp.a_eq('11 servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('11 en_curso', v_r ->> 'en_curso', NULL);
  v_op := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('11 open', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('11 open servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('11 open via_actual', v_r ->> 'via_actual', NULL);

  -- ---- 12. recarga words without a promo; the amount alone is not enough without a promo ------------------------------------
  UPDATE promo_etecsa SET estado = 'descartada' WHERE huella = md5('assert-265-vigente');
  SELECT * INTO c FROM pg_temp.a_conv(13);
  PERFORM pg_temp.a_msg(c.conv, 'quiero hacer una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('12 words', v_r, 'ninguna', 'recarga_sin_promo');
  PERFORM pg_temp.a_eq('12 servicio', v_r ->> 'servicio', 'remesa');
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');   -- the window starts at the holder's creation
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('12 words + deposit', v_r, 'ninguna', 'recarga_sin_promo');
  SELECT * INTO c FROM pg_temp.a_conv(14);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_parcial(c.conv, NULL, '55501014');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('12 amount without promo', v_r, 'ninguna', 'sin_cambio');
  UPDATE promo_etecsa SET estado = 'confirmada' WHERE huella = md5('assert-265-vigente');

  -- ---- 13. combo words (Q7), and a deposit below the combo minimum ----------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(15);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 25000, true);
  PERFORM pg_temp.a_msg(c.conv, 'quiero mandar un combo');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('13', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('13 convertir_a', v_r ->> 'convertir_a', 'combo');
  UPDATE remittance_operation_receipts SET amount = 5000 WHERE operation_id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = 5000 WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('13 below minimum', v_r, 'ninguna', 'deposito_bajo_minimo');
  PERFORM pg_temp.a_eq('13 minimo', v_r ->> 'minimo_gyd', '25000');
  PERFORM pg_temp.a_eq('13 faltante', v_r ->> 'faltante_gyd', '20000');

  -- ---- 14. visa: the bare word is a card, the explicit phrase is an extension -------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(16);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  PERFORM pg_temp.a_msg(c.conv, 'es para mi tarjeta visa');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('14 bare visa', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('14 bare visa flag', v_r #>> '{evidencia,palabras,visa}', 'false');
  SELECT * INTO c FROM pg_temp.a_conv(17);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 5000, true);
  PERFORM pg_temp.a_msg(c.conv, 'necesito la extensión de visa');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('14 explicit visa', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('14 convertir_a', v_r ->> 'convertir_a', 'visa');

  -- ---- 15. a human lock excludes; a lock the bot left does not ----------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(18);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');
  PERFORM set_config('wacrm.origin', 'admin', true);   -- the lock map is writable only by a human / asserted admin origin
  UPDATE remittance_operations
     SET admin_locked_fields = jsonb_build_object('service_type', jsonb_build_object('by', 'user:test265', 'at', now()))
   WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('15 human lock', v_r, 'ninguna', 'bloqueada');
  UPDATE remittance_operations
     SET admin_locked_fields = jsonb_build_object('service_type', jsonb_build_object('by', 'automation:cerebro_cambiar_servicio', 'at', now()))
   WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('15 bot lock', v_r, 'convertir', 'palabras');
  PERFORM set_config('wacrm.origin', '', true);

  -- ---- 16. a completed operation is never converted, and words typed before it closed are not read again -----------------------
  SELECT * INTO c FROM pg_temp.a_conv(19);
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (c.conv, 'customer', 'text', 'quiero una recarga', now() - interval '1 hour');
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', 'cuban_card', 6200, true);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  IF (SELECT status FROM remittance_operations WHERE id = v_op) <> 'completed' THEN RAISE EXCEPTION 'fixture: could not complete'; END IF;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('16', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('16 en_curso', v_r ->> 'en_curso', NULL);
  PERFORM pg_temp.a_eq('16 operaciones', jsonb_array_length(v_r -> 'operaciones')::text, '0');
  PERFORM pg_temp.a_eq('16 old words ignored', v_r #>> '{evidencia,palabras,recarga}', 'false');

  -- ---- 17. error path: fail open ------------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(20);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  UPDATE cerebro_config SET valor = 'not-a-number' WHERE clave = 'minimo_gyd_cup';
  v_r := cerebro_resolver_servicio(c.conv, NULL, 'es para una recarga');
  PERFORM pg_temp.a_chk('17', v_r, 'ninguna', 'error');
  PERFORM pg_temp.a_eq('17 version', v_r ->> 'version', '1');
  PERFORM pg_temp.a_eq('17 confianza', v_r ->> 'confianza', 'baja');
  PERFORM pg_temp.a_eq('17 cancelar', v_r ->> 'cancelar', '[]');
  UPDATE cerebro_config SET valor = v_cup::text WHERE clave = 'minimo_gyd_cup';

  -- ---- 18. ACL and shape ----------------------------------------------------------------------------------------------------------
  IF has_function_privilege('anon', 'public.cerebro_resolver_servicio(uuid,text,text,numeric,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 18: anon can execute'; END IF;
  IF NOT has_function_privilege('service_role', 'public.cerebro_resolver_servicio(uuid,text,text,numeric,timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cerebro_resolver_servicio(uuid,text,text,numeric,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 18: authenticated / service_role cannot execute'; END IF;
  IF (SELECT p.provolatile::text || p.prosecdef::text FROM pg_proc p WHERE p.proname = 'cerebro_resolver_servicio') IS DISTINCT FROM 'strue' THEN
    RAISE EXCEPTION 'case 18: not STABLE SECURITY DEFINER'; END IF;

  -- ---- 19. the agent's declaration, and a deposit not registered yet ---------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(21);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  v_r := cerebro_resolver_servicio(c.conv, 'recarga');
  PERFORM pg_temp.a_chk('19 declared', v_r, 'convertir', 'declarado');
  v_r := cerebro_resolver_servicio(c.conv, 'zelle');
  PERFORM pg_temp.a_chk('19 declared rail on a remesa', v_r, 'ninguna', 'declarado_riel');
  SELECT * INTO c FROM pg_temp.a_conv(22);
  PERFORM pg_temp.a_parcial(c.conv, NULL, '55501022');
  v_r := cerebro_resolver_servicio(c.conv, NULL, NULL, 6200);
  PERFORM pg_temp.a_chk('19 p_monto no operation', v_r, 'ninguna', 'monto_precio_y_celular');
  PERFORM pg_temp.a_eq('19 servicio', v_r ->> 'servicio', 'recarga');
  PERFORM pg_temp.a_eq('19 fuente', v_r #>> '{evidencia,monto_fuente}', 'parametro');
  v_r := cerebro_resolver_servicio(c.conv, NULL, NULL, 5000);
  PERFORM pg_temp.a_chk('19 p_monto other amount', v_r, 'ninguna', 'sin_cambio');
  -- an empty remesa waiting for its deposit becomes the recarga when the 6,200 arrives
  v_op := pg_temp.a_op(c, 'collecting_information', 'remesa', NULL, 0, false);
  v_r := cerebro_resolver_servicio(c.conv, NULL, NULL, 6200);
  PERFORM pg_temp.a_chk('19 p_monto empty remesa', v_r, 'convertir', 'monto_precio_y_celular');
  PERFORM pg_temp.a_eq('19 destino', v_r ->> 'destino_operacion', v_op::text);

  -- ---- 20. OWNER RULE: the customer can always change the service of the holder; coverage decides ---------------------------------
  -- 20a recarga with numbers + "mejor a una tarjeta" + 6,200 -> the CUP card (the deposit meets the card minimum, not both)
  SELECT * INTO c FROM pg_temp.a_conv(23);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'recarga', NULL, 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'recarga', NULL, '55501023');
  PERFORM pg_temp.a_msg(c.conv, 'mejor a una tarjeta');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('20a', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('20a convertir_a', v_r ->> 'convertir_a', 'cuban_card');
  PERFORM pg_temp.a_eq('20a destino', v_r ->> 'destino_operacion', v_op::text);
  PERFORM pg_temp.a_eq('20a en_curso', v_r ->> 'en_curso', 'recarga');
  PERFORM pg_temp.a_eq('20a via_actual', v_r ->> 'via_actual', NULL);
  -- 20b the deposit pays both the recarga it holds and the card (6,200 + 5,000): a mixed send
  UPDATE remittance_operation_receipts SET amount = 6200 + v_cup WHERE operation_id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = 6200 + v_cup WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('20b', v_r, 'adicional', 'deposito_cubre_ambos');
  PERFORM pg_temp.a_eq('20b servicio', v_r ->> 'servicio', 'cuban_card');
  PERFORM pg_temp.a_eq('20b monto', v_r #>> '{adicionales,0,monto}', v_cup::text);
  -- 20c remesa with a card + "es para una recarga" + 6,200 -> the recarga (own data does not block the change)
  SELECT * INTO c FROM pg_temp.a_conv(24);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('20c', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('20c convertir_a', v_r ->> 'convertir_a', 'recarga');
  -- 20d recarga 6,200 + "mejor zelle": below the Zelle minimum -> no change, with the minimum and the shortfall
  SELECT * INTO c FROM pg_temp.a_conv(25);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'recarga', NULL, 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'recarga', NULL, '55501025');
  PERFORM pg_temp.a_msg(c.conv, 'mejor zelle');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('20d', v_r, 'ninguna', 'deposito_bajo_minimo');
  PERFORM pg_temp.a_eq('20d minimo', v_r ->> 'minimo_gyd', v_usd::text);
  PERFORM pg_temp.a_eq('20d faltante', v_r ->> 'faltante_gyd', (v_usd - 6200)::text);
  PERFORM pg_temp.a_eq('20d servicio_minimo', v_r ->> 'servicio_minimo', 'zelle');
  PERFORM pg_temp.a_eq('20d servicio stays', v_r ->> 'servicio', 'recarga');
  -- 20e a remesa to Zelle changed to saldo (any direction): saldo needs no promo
  SELECT * INTO c FROM pg_temp.a_conv(26);
  v_op := pg_temp.a_op(c, 'ready_to_transfer', 'remesa', 'zelle', v_usd + 1000, true);
  PERFORM pg_temp.a_msg(c.conv, 'mejor un saldo movil');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('20e', v_r, 'adicional', 'deposito_cubre_ambos');
  UPDATE remittance_operation_receipts SET amount = 3000 WHERE operation_id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = 3000 WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('20e saldo', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('20e convertir_a', v_r ->> 'convertir_a', 'saldo');

  -- ---- 21. reverse safety net (Q1): data of another rail on a recarga that was never named ----------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(27);
  v_op := pg_temp.a_op(c, 'collecting_information', 'recarga', NULL, 0, false);
  PERFORM pg_temp.a_parcial(c.conv, c_card, NULL);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('21 empty recarga + card', v_r, 'convertir', 'datos_de_otro_servicio');
  PERFORM pg_temp.a_eq('21 convertir_a', v_r ->> 'convertir_a', 'cuban_card');
  -- with numbers and a deposit that meets the card minimum it converts too (no "ask" branch for numbers)
  SELECT * INTO c FROM pg_temp.a_conv(28);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'recarga', NULL, 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'recarga', NULL, '55501028');
  PERFORM pg_temp.a_parcial(c.conv, c_card, NULL);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('21 numbers + card', v_r, 'convertir', 'datos_de_otro_servicio');
  -- the customer names the recarga AFTER the card data: the recarga is the latest signal, nothing to change
  PERFORM pg_temp.a_msg(c.conv, 'es una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('21 recarga named after the card', v_r, 'ninguna', 'sin_cambio');
  -- ... and a card typed AFTER the word supersedes it: latest wins
  PERFORM pg_temp.a_msg(c.conv, 'mejor a esta tarjeta ' || c_card);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('21 card after the word', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('21 convertir_a', v_r ->> 'convertir_a', 'cuban_card');
  -- same burst (one message with the word and the data): ask once
  SELECT * INTO c FROM pg_temp.a_conv(36);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'recarga', NULL, 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'recarga', NULL, '55501036');
  v_r := cerebro_resolver_servicio(c.conv, NULL, 'es una recarga y esta tarjeta ' || c_card);
  PERFORM pg_temp.a_chk('21 same burst', v_r, 'preguntar', 'datos_de_otro_servicio');
  PERFORM pg_temp.a_eq('21 opciones', (v_r #>> '{pregunta,opciones}'), '["recarga", "cuban_card"]');

  -- ---- 22. two services named and the holder is neither ----------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(29);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 25000, true);
  PERFORM pg_temp.a_msg(c.conv, 'una recarga y un combo');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('22', v_r, 'preguntar', 'palabras_ambiguas');
  PERFORM pg_temp.a_eq('22 confianza', v_r ->> 'confianza', 'baja');

  -- ---- 23. incident / transferring are excluded ----------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(30);
  v_op := pg_temp.a_op(c, 'incident', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_msg(c.conv, 'es para una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('23 incident', v_r, 'ninguna', 'estado_no_permite');
  UPDATE remittance_operations SET status = 'transferring' WHERE id = v_op;
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('23 transferring', v_r, 'ninguna', 'estado_no_permite');

  -- ---- 24. a negated mention is not an order ---------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(31);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  PERFORM pg_temp.a_msg(c.conv, 'no quiero recarga, es una transferencia');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('24', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('24 flag', v_r #>> '{evidencia,palabras,recarga}', 'false');

  -- ---- 25. latest wins on a genuine change of mind --------------------------------------------------------------------------------------
  -- recarga holder, "es una recarga" then "mejor a esta tarjeta <card>" -> the CUP card
  SELECT * INTO c FROM pg_temp.a_conv(37);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'recarga', NULL, 6200, true);
  PERFORM pg_temp.a_ben(v_op, 'recarga', NULL, '55501037');
  PERFORM pg_temp.a_msg(c.conv, 'es una recarga');
  PERFORM pg_temp.a_msg(c.conv, 'mejor a esta tarjeta ' || c_card);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('25 recarga -> card', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('25 convertir_a', v_r ->> 'convertir_a', 'cuban_card');
  -- remesa to a card, "recarga" then "no, mejor a esta tarjeta": the recarga is superseded
  SELECT * INTO c FROM pg_temp.a_conv(38);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_msg(c.conv, 'es una recarga');
  PERFORM pg_temp.a_msg(c.conv, 'no, mejor a esta tarjeta ' || c_card);
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('25 recarga superseded by a card', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('25 activas', v_r #>> '{evidencia,activas}', '[]');
  -- a later service word supersedes an earlier one (combo, then "mejor una recarga")
  SELECT * INTO c FROM pg_temp.a_conv(39);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 25000, true);
  PERFORM pg_temp.a_msg(c.conv, 'quiero un combo');
  PERFORM pg_temp.a_msg(c.conv, 'mejor una recarga');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('25 combo then recarga', v_r, 'convertir', 'palabras');
  PERFORM pg_temp.a_eq('25 convertir_a', v_r ->> 'convertir_a', 'recarga');

  -- ---- 26. a price / promo question is not a request (but a polite request is) -------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.a_conv(40);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', 'cuban_card', 5000, true);
  PERFORM pg_temp.a_ben(v_op, 'cuban_card', c_card, NULL);
  PERFORM pg_temp.a_msg(c.conv, '¿cuánto es la recarga?');
  PERFORM pg_temp.a_msg(c.conv, '¿hay promo de recarga?');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('26 questions', v_r, 'ninguna', 'sin_cambio');
  PERFORM pg_temp.a_eq('26 flag', v_r #>> '{evidencia,palabras,recarga}', 'false');
  SELECT * INTO c FROM pg_temp.a_conv(41);
  v_op := pg_temp.a_op(c, 'deposit_verification', 'remesa', NULL, 6200, true);
  PERFORM pg_temp.a_msg(c.conv, '¿me puedes hacer una recarga?');
  v_r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.a_chk('26 polite request', v_r, 'convertir', 'palabras');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
