\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 283 (cambiar_servicio absorbs what marcar_destino_usd did: every rail is a service target through
-- cerebro_aplicar_servicio; words like cup / efectivo / pesos are understood by the DB; the change targets the operation of the
-- right service and is allowed before any money exists).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Synthetic fixtures only: contacts 'PRUEBA servicio N', phones 5990283xxxx.
-- Cases (number = label in the failure message):
--   1  before any deposit an empty Zelle operation becomes cash / clasica / tropical / CUP (it used to answer deposito_bajo_minimo)
--   2  the words: cup, pesos, tarjeta cup, efectivo, Efectivo USD, CLASICA, Tropical resolve to their rail; declarar_servicio('cup') stores cuban_card
--   3  two open operations, no deposit (planned zelle + mexico): "efectivo" converts the REMESA (zelle); the Mexico operation is untouched;
--      the waiting plan follows the new rail
--   4  an open operation already of the requested service: no change (sin_cambio), nothing converted
--   5  two open remesas with no deposit: still ambiguous (varias_operaciones), nothing changed
--   6  a clasica remesa next to a recarga (mixed send before the deposit): "efectivo" converts the remesa, the recarga stays open
--   7  with a verified-size deposit the rules are unchanged: below the minimum -> deposito_bajo_minimo; above -> converts
--   8  marcar_destino_usd still works (compat) and is documented as deprecated
-- =====================================================================
CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990283' || lpad(p_n::text, 4, '0'), 'PRUEBA servicio ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.p_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.p_verifica(p_conv uuid, p_monto numeric, p_ref text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en) VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test280', now());
  SELECT r.deal_id INTO v_id FROM pg_temp.p_registra(p_conv, p_monto, p_ref) r;
  PERFORM cerebro_cruzar_depositos(v_id, ARRAY[p_ref], ARRAY[p_monto],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', '3cf01654-cd27-47c1-ac92-62abf5435751');
END $f$;


CREATE FUNCTION pg_temp.p_rail(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(cerebro_riel_op(o.id), ',' ORDER BY cerebro_riel_op(o.id)), '') FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

DO $$
DECLARE
  c record; r jsonb; v_w text; v_exp text; i int := 100;
  v_words text[] := ARRAY['cup', 'pesos', 'tarjeta cup', 'efectivo', 'Efectivo USD', 'CLASICA', 'Tropical'];
  v_rails text[] := ARRAY['cuban_card', 'cuban_card', 'cuban_card', 'efectivo_usd', 'efectivo_usd', 'clasica', 'tropical'];
  v_op uuid; v_m text;
BEGIN
  -- 1 + 2 empty Zelle operation, every word
  FOR k IN 1 .. array_length(v_words, 1) LOOP
    i := i + 1;
    SELECT * INTO c FROM pg_temp.p_conv(i);
    PERFORM cerebro_guardar_zelle(c.conv, 'Ruben Ortiz', 'ruben.' || i || '@example.com', 'k' || i);
    r := cerebro_aplicar_servicio(c.conv, v_words[k], 'cambiar', 'agent:cambiar_servicio', 'e' || i);
    PERFORM pg_temp.p_eq('2 ' || v_words[k], (r ->> 'aplicado') || '/' || pg_temp.p_rail(c.conv), 'true/' || v_rails[k]);
    PERFORM pg_temp.p_eq('2 message ' || v_words[k], (r ->> 'mensaje' IS NOT NULL AND r ->> 'mensaje' <> '')::text, 'true');
  END LOOP;
  SELECT * INTO c FROM pg_temp.p_conv(150);
  r := cerebro_declarar_servicio(c.conv, 'cup', 'agent:declarar_servicio');
  PERFORM pg_temp.p_eq('2 declarar cup', (r ->> 'ok') || '/' || (r ->> 'servicio'), 'true/cuban_card');

  -- 3 planned zelle + mexico, no deposit: efectivo converts the remesa only
  SELECT * INTO c FROM pg_temp.p_conv(151);
  PERFORM cerebro_repartir_envio(c.conv, 'zelle 20000, mexico 20000', 'e3a');
  r := cerebro_aplicar_servicio(c.conv, 'efectivo', 'cambiar', 'agent:cambiar_servicio', 'e3b');
  PERFORM pg_temp.p_eq('3 applied', r ->> 'aplicado', 'true');
  PERFORM pg_temp.p_eq('3 rails', pg_temp.p_rail(c.conv), 'efectivo_usd,mexico');
  PERFORM pg_temp.p_eq('3 plan follows', (SELECT string_agg(e ->> 'servicio', ',' ORDER BY ord) FROM cerebro_reparto_planeado pl, jsonb_array_elements(pl.partes) WITH ORDINALITY t(e, ord) WHERE pl.conversation_id = c.conv), 'efectivo_usd,mexico');

  -- 4 already of that service
  r := cerebro_aplicar_servicio(c.conv, 'cash', 'cambiar', 'agent:cambiar_servicio', 'e4');
  PERFORM pg_temp.p_eq('4 no change', (r ->> 'aplicado') || '/' || (r ->> 'motivo') || '/' || pg_temp.p_rail(c.conv), 'false/sin_cambio/efectivo_usd,mexico');

  -- 5 two remesas, no deposit
  SELECT * INTO c FROM pg_temp.p_conv(152);
  PERFORM cerebro_repartir_envio(c.conv, 'zelle 20000, clasica 20000', 'e5a');
  r := cerebro_aplicar_servicio(c.conv, 'efectivo', 'cambiar', 'agent:cambiar_servicio', 'e5b');
  PERFORM pg_temp.p_eq('5 ambiguous', (r ->> 'aplicado') || '/' || (r ->> 'motivo') || '/' || pg_temp.p_rail(c.conv), 'false/varias_operaciones/clasica,zelle');

  -- 6 clasica remesa + recarga
  SELECT * INTO c FROM pg_temp.p_conv(153);
  PERFORM cerebro_repartir_envio(c.conv, 'clasica 20000, recarga 6000', 'e6a');
  r := cerebro_aplicar_servicio(c.conv, 'efectivo', 'cambiar', 'agent:cambiar_servicio', 'e6b');
  PERFORM pg_temp.p_eq('6 remesa converted, recarga kept', (r ->> 'aplicado') || '/' || pg_temp.p_rail(c.conv), 'true/efectivo_usd,recarga');

  -- 7 money present: unchanged rules (the deposit decides)
  SELECT * INTO c FROM pg_temp.p_conv(154);
  PERFORM cerebro_guardar_zelle(c.conv, 'Ruben Ortiz', 'ruben.154@example.com', 'k154');
  PERFORM pg_temp.p_verifica(c.conv, 13000, '90409990030001');
  r := cerebro_aplicar_servicio(c.conv, 'efectivo', 'cambiar', 'agent:cambiar_servicio', 'e7a');
  PERFORM pg_temp.p_eq('7 below the cash minimum', (r ->> 'aplicado') || '/' || (r ->> 'motivo'), 'false/deposito_bajo_minimo');
  SELECT * INTO c FROM pg_temp.p_conv(155);
  PERFORM cerebro_guardar_zelle(c.conv, 'Ruben Ortiz', 'ruben.155@example.com', 'k155');
  PERFORM pg_temp.p_verifica(c.conv, 40000, '90409990030002');
  r := cerebro_aplicar_servicio(c.conv, 'tropical', 'cambiar', 'agent:cambiar_servicio', 'e7b');
  PERFORM pg_temp.p_eq('7 enough', (r ->> 'aplicado') || '/' || pg_temp.p_rail(c.conv), 'true/tropical');

  -- 8 compat + deprecation
  SELECT * INTO c FROM pg_temp.p_conv(156);
  PERFORM cerebro_guardar_zelle(c.conv, 'Ruben Ortiz', 'ruben.156@example.com', 'k156');
  SELECT accion INTO v_m FROM cerebro_marcar_destino_usd(c.conv, 'clasica', 'e8');
  PERFORM pg_temp.p_eq('8 marcar still works', (v_m LIKE 'destino marcado%' OR v_m LIKE 'ERROR:%')::text, 'true');
  PERFORM pg_temp.p_eq('8 deprecated', (obj_description('public.cerebro_marcar_destino_usd(uuid,text,text)'::regprocedure, 'pg_proc') LIKE 'DEPRECATED%')::text, 'true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
