\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 279 (cerebro_aplicar_servicio always answers a plain-Spanish mensaje). Self-reverting:
-- BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA mensaje N', phones 5990279xxxx.
-- odd/notes/db-tools-progress.md (279, gap 5 of the S5b measurement: F1 agregar recarga -> mensaje null, nueva_operacion).
-- Cases (number = label in the failure message):
--   1  agregar with no operation open (motivo nueva_operacion): a mensaje that names the service
--   2  cambiar with no operation open and below the minimum, and with a valid target: mensaje not null
--   3  sin_cambio with a declaration (the operation already is that service) and without any declaration: mensaje not null
--   4  aparte twice: the second answers ya_existe_vacia with a mensaje
--   5  every motivo reachable here (invalid service / intention, no conversation) carries a mensaje; applied calls keep theirs
--   6  cerebro_resolver_servicio itself returns a mensaje for these motivos
-- =====================================================================

CREATE FUNCTION pg_temp.m_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990279' || lpad(p_n::text, 4, '0'), 'PRUEBA mensaje ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.m_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

DO $$
DECLARE
  c record; r jsonb; v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
BEGIN
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT 279', 'https://assert.invalid/279', 'assert', md5('assert-279-vigente'), 'confirmada');

  -- 1 agregar with nothing open
  SELECT * INTO c FROM pg_temp.m_conv(1);
  r := cerebro_aplicar_servicio(c.conv, 'recarga', 'agregar', 'agent:agregar_servicio', 'e1');
  PERFORM pg_temp.m_eq('1 motivo', r ->> 'motivo', 'nueva_operacion');
  PERFORM pg_temp.m_eq('1 mensaje names the service', (r ->> 'mensaje' ILIKE '%recarga%')::text, 'true');
  PERFORM pg_temp.m_eq('1 permitido', r ->> 'permitido', 'true');

  -- 2 cambiar with nothing open
  SELECT * INTO c FROM pg_temp.m_conv(2);
  r := cerebro_aplicar_servicio(c.conv, 'clasica', 'cambiar', 'agent:cambiar_servicio', 'e2');
  PERFORM pg_temp.m_eq('2 mensaje not null', (r ->> 'mensaje' IS NOT NULL)::text, 'true');

  -- 3 sin_cambio
  SELECT * INTO c FROM pg_temp.m_conv(3);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
  VALUES (c.acc, c.conv, c.contact, 'collecting_information', 'remesa', 'clasica', 'GYD', 0);
  r := cerebro_aplicar_servicio(c.conv, 'clasica', 'agregar', 'agent:agregar_servicio', 'e3');
  PERFORM pg_temp.m_eq('3 sin_cambio motivo', r ->> 'motivo', 'sin_cambio');
  PERFORM pg_temp.m_eq('3 sin_cambio mensaje', (r ->> 'mensaje' IS NOT NULL AND r ->> 'mensaje' ILIKE '%clásica%')::text, 'true');
  SELECT * INTO c FROM pg_temp.m_conv(4);
  r := cerebro_resolver_servicio(c.conv);
  PERFORM pg_temp.m_eq('3 nothing to do mensaje', (r ->> 'mensaje' IS NOT NULL)::text, 'true');

  -- 4 aparte twice: money on the holder so the resolver proposes a separate operation
  SELECT * INTO c FROM pg_temp.m_conv(5);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
  VALUES (c.acc, c.conv, c.contact, 'deposit_verification', 'remesa', 'clasica', 'GYD', 14000);
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, receipt_status, reference, source)
  SELECT o.id, c.conv, 'COMP-279a', 14000, 'GYD', 'verificado', '279001', 'bot' FROM remittance_operations o WHERE o.conversation_id = c.conv;
  r := cerebro_aplicar_servicio(c.conv, 'zelle', 'agregar', 'agent:agregar_servicio', 'e5a');
  PERFORM pg_temp.m_eq('4 first aparte applied', r ->> 'aplicado', 'true');
  PERFORM pg_temp.m_eq('4 first mensaje', (r ->> 'mensaje' IS NOT NULL)::text, 'true');
  r := cerebro_aplicar_servicio(c.conv, 'zelle', 'agregar', 'agent:agregar_servicio', 'e5b');
  PERFORM pg_temp.m_eq('4 second is not applied', r ->> 'aplicado', 'false');
  PERFORM pg_temp.m_eq('4 second motivo', r ->> 'motivo', 'ya_existe_vacia');
  PERFORM pg_temp.m_eq('4 second mensaje', (r ->> 'mensaje' IS NOT NULL AND r ->> 'mensaje' ILIKE '%ya hay%')::text, 'true');

  -- 5 invalid inputs and no conversation
  r := cerebro_aplicar_servicio(c.conv, 'paypal', 'agregar', 'agent:agregar_servicio', 'e6');
  PERFORM pg_temp.m_eq('5 servicio_invalido', (r ->> 'mensaje' IS NOT NULL)::text, 'true');
  r := cerebro_aplicar_servicio(c.conv, 'clasica', 'inventar', 'agent:agregar_servicio', 'e7');
  PERFORM pg_temp.m_eq('5 intencion_invalida', (r ->> 'mensaje' IS NOT NULL)::text, 'true');
  r := cerebro_aplicar_servicio(NULL, 'clasica', 'agregar', 'agent:agregar_servicio', 'e8');
  PERFORM pg_temp.m_eq('5 sin_conversacion', (r ->> 'mensaje' IS NOT NULL)::text, 'true');

  -- 6 the resolver itself
  SELECT * INTO c FROM pg_temp.m_conv(6);
  r := cerebro_resolver_servicio(c.conv, 'recarga', 'agregar');
  PERFORM pg_temp.m_eq('6 resolver nueva_operacion mensaje', (r ->> 'mensaje' IS NOT NULL)::text, 'true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
