\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 289 (the declaration of the service is a consequence of the quote / of opening a recharge).
-- Self-reverting. Synthetic fixtures: contacts 'PRUEBA implicita N', phones 5990289xxxx.
-- Cases:
--   1  a quote that names its service declares it (implicit:cotizar): via mexico / clasica / tropical / zelle; a CUP quote = cuban_card; a cash via = efectivo_usd;
--      an empty via and usdt declare nothing
--   2  a declaration the bot made explicitly is never replaced by a quote (zelle declared, then a mexico quote -> zelle stays); an implicit one is replaced by the next quote
--      (mexico, then clasica -> clasica); an explicit declaration after implicit ones sticks
--   3  money of another service already in the conversation: a quote about a price declares nothing
--   4  crm_registrar_numeros_recarga with p_abrir declares recarga; without p_abrir (and without a promo) it does not
--   5  the later deposit attaches to the declared service: mexico quote then a 13,000 deposit -> the operation is the Mexico one; recarga numbers then 6,200 -> the one recarga
-- =====================================================================
CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990289' || lpad(p_n::text, 4, '0'), 'PRUEBA implicita ' || p_n, v_acc) RETURNING id INTO v_ct;
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

-- "rail/amount" of every open operation, sorted
CREATE FUNCTION pg_temp.p_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(cerebro_riel_op(o.id) || '/' || coalesce(o.quoted_source_amount::int::text, '-'), ';' ORDER BY cerebro_riel_op(o.id)), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.p_plan(p_conv uuid) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT cerebro_resolver_servicio(p_conv) -> 'reparto_planeado'; $f$;

-- a deposit that is verified: MMG row in the ledger + registrar + cruce (same as split-deposit-minimums)
CREATE FUNCTION pg_temp.p_verifica(p_conv uuid, p_monto numeric, p_ref text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en) VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test280', now());
  SELECT r.deal_id INTO v_id FROM pg_temp.p_registra(p_conv, p_monto, p_ref) r;
  PERFORM cerebro_cruzar_depositos(v_id, ARRAY[p_ref], ARRAY[p_monto],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', '3cf01654-cd27-47c1-ac92-62abf5435751');
END $f$;

CREATE FUNCTION pg_temp.p_decl(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$ SELECT coalesce((SELECT servicio || '/' || coalesce(actor, '-') FROM cerebro_servicio_declarado WHERE conversation_id = p_conv), '-'); $f$;

DO $$
DECLARE c record; r jsonb; v_via text; i int := 0; v_op uuid;
  v_vias text[] := ARRAY['mexico', 'clasica', 'tropical', 'zelle', 'Clásica'];
  v_exp  text[] := ARRAY['mexico', 'clasica', 'tropical', 'zelle', 'clasica'];
BEGIN
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-289'), 'confirmada');

  -- 1
  FOR i IN 1 .. array_length(v_vias, 1) LOOP
    SELECT * INTO c FROM pg_temp.p_conv(i);
    r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', v_vias[i], 'q' || i);
    PERFORM pg_temp.p_eq('1 quote ok ' || v_vias[i], r ->> 'ok', 'true');
    PERFORM pg_temp.p_eq('1 declared ' || v_vias[i], pg_temp.p_decl(c.conv), v_exp[i] || '/implicit:cotizar');
  END LOOP;
  SELECT * INTO c FROM pg_temp.p_conv(10);
  r := cerebro_cotizar(c.conv, 15000, 'desde_deposito', 'cup', NULL, 'q10');
  PERFORM pg_temp.p_eq('1 cup quote', (r ->> 'ok') || '/' || pg_temp.p_decl(c.conv), 'true/cuban_card/implicit:cotizar');
  SELECT * INTO c FROM pg_temp.p_conv(11);
  r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', 'efectivo', 'q11');
  PERFORM pg_temp.p_eq('1 cash', (r ->> 'reason') || '/' || pg_temp.p_decl(c.conv), 'efectivo_tiene_tasa_propia/efectivo_usd/implicit:cotizar');
  SELECT * INTO c FROM pg_temp.p_conv(12);
  r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', NULL, 'q12');
  PERFORM pg_temp.p_eq('1 empty via names nothing', pg_temp.p_decl(c.conv), '-');
  r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', 'usdt', 'q12b');
  PERFORM pg_temp.p_eq('1 usdt names nothing', pg_temp.p_decl(c.conv), '-');

  -- 2
  SELECT * INTO c FROM pg_temp.p_conv(20);
  PERFORM cerebro_declarar_servicio(c.conv, 'zelle', 'agent:declarar_servicio');
  r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', 'mexico', 'q20');
  PERFORM pg_temp.p_eq('2 explicit zelle stays', pg_temp.p_decl(c.conv), 'zelle/agent:declarar_servicio');
  SELECT * INTO c FROM pg_temp.p_conv(21);
  r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', 'mexico', 'q21a');
  r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', 'clasica', 'q21b');
  PERFORM pg_temp.p_eq('2 implicit replaced by the next quote', pg_temp.p_decl(c.conv), 'clasica/implicit:cotizar');
  PERFORM cerebro_declarar_servicio(c.conv, 'zelle', 'agent:declarar_servicio');
  r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', 'tropical', 'q21c');
  PERFORM pg_temp.p_eq('2 explicit after implicit sticks', pg_temp.p_decl(c.conv), 'zelle/agent:declarar_servicio');

  -- 3 money of another service
  SELECT * INTO c FROM pg_temp.p_conv(30);
  PERFORM cerebro_guardar_zelle(c.conv, 'Marta Gil', 'marta@example.com', 'q30a');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = c.conv;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, operation_id, consumido_en) VALUES ('9040999004100', 26000, 'GYD', 'Osmany', 'test289', now(), v_op, now());
  r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', 'mexico', 'q30b');
  PERFORM pg_temp.p_eq('3 money of zelle: a mexico quote declares nothing', pg_temp.p_decl(c.conv), '-');
  r := cerebro_cotizar(c.conv, 100, 'hacia_destino', 'usd', 'zelle', 'q30c');
  PERFORM pg_temp.p_eq('3 same service as the money: declared', pg_temp.p_decl(c.conv), 'zelle/implicit:cotizar');

  -- 4 recarga numbers
  SELECT * INTO c FROM pg_temp.p_conv(40);
  PERFORM crm_registrar_numeros_recarga(c.conv, '55501111', true, 'agent:registrar_numeros_recarga');
  PERFORM pg_temp.p_eq('4 p_abrir declares recarga', pg_temp.p_decl(c.conv), 'recarga/agent:registrar_numeros_recarga');
  SELECT * INTO c FROM pg_temp.p_conv(41);
  PERFORM crm_registrar_numeros_recarga(c.conv, '55501111');
  PERFORM pg_temp.p_eq('4 without p_abrir nothing is declared', pg_temp.p_decl(c.conv), '-');

  -- 5 the later deposit attaches to the declared service
  SELECT * INTO c FROM pg_temp.p_conv(50);
  r := cerebro_cotizar(c.conv, 50, 'hacia_destino', 'usd', 'mexico', 'q50');
  PERFORM pg_temp.p_registra(c.conv, 13000, '9040999004101');
  PERFORM pg_temp.p_eq('5 mexico operation from the quote', (SELECT string_agg(service_type, ',') FROM remittance_operations WHERE conversation_id = c.conv AND status NOT IN ('completed', 'cancelled')), 'mexico');
  SELECT * INTO c FROM pg_temp.p_conv(51);
  PERFORM crm_registrar_numeros_recarga(c.conv, '55501111', true, 'agent:registrar_numeros_recarga');
  PERFORM pg_temp.p_registra(c.conv, 6200, '9040999004102');
  PERFORM pg_temp.p_eq('5 the one recarga holds the deposit', (SELECT string_agg(service_type || ':' || trim_scale(quoted_source_amount)::text, ',') FROM remittance_operations WHERE conversation_id = c.conv AND status NOT IN ('completed', 'cancelled')), 'recarga:6200');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
