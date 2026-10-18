\set ON_ERROR_STOP on
-- (2026-10-02 convention) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- cerebro-cotizar.sql — self-reverting assertion for 243_cerebro_cotizar.sql
-- (odd/tasks/cerebro-tool-consolidation.md T3: the four calculator tools become one).
--
-- The point of this file is PARITY, not arithmetic taste. Each case runs the ORIGINAL expression of
-- the tool it replaces, inline and against the SAME live `tasas` row, and demands the merged
-- function return exactly that. No fixture rate is created: `tasas` is a VIEW and rejects INSERT
-- (tasas-derives.sql case 5), and parity is relative anyway — comparing both sides under the real
-- rate is the stronger test.
--
-- NOTE on cerebro_ultima_cotizacion: its PK is (conversation_id, destino_moneda), so there is at
-- most ONE row per currency and every new quote REPLACES it. The label cases therefore read the
-- row immediately after the call whose label they are checking.
--
--   case a — desde_deposito + cup  == calcular_envio          (round(monto * tasa))
--   case b — hacia_destino  + cup  == calcular_inverso        (ceil((cup/tasa)/20)*20)
--   case c — hacia_destino  + usd, via clasica == calcular_usd with the single rate
--   case d — hacia_destino  + usd, via zelle   == calcular_usd through cerebro_tasa_zelle (tiers)
--   case e — desde_deposito + usd, via clasica == calcular_usd_desde_gyd (floor(gyd/tasa))
--   case f — desde_deposito + usd, via zelle   == calcular_usd_desde_gyd through
--            cerebro_zelle_cotizar_gyd
--   case g — the preserved HERRAMIENTA label: each direction leaves the old tool's name, so the
--            audit and the coherence net keep the meaning they have today
--   case h — DIVERGENCE 1: efectivo is refused, writing nothing. Also proves WHY: the old
--            single-rate regex does not match 'efectivo', so the old tools quoted cash as Zelle by
--            tiers — the wrong rate, silently
--   case i — refusals (unknown direction, unknown destination currency, non-positive amount, NULL
--            conversation) and accepted aliases
--   case j — grants: service_role yes; anon and authenticated no

SAVEPOINT cerebro_cotizar;

DO $$
DECLARE
  v_owner_user uuid := gen_random_uuid();
  v_dummy_hash CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_sig CONSTANT text := 'public.cerebro_cotizar(uuid, numeric, text, text, text, text)';
  v_acc   uuid;
  v_ct    uuid;
  v_conv  uuid;
  v_r     jsonb;
  v_tasa_gyd numeric;
  v_tasa_usd numeric;
  v_esp_destino numeric;
  v_esp_gyd     numeric;
  v_esp_tasa    numeric;
  v_usd   numeric;
  v_herr  text;
  v_herr_antes text;
  v_n_antes integer;
  v_n_despues integer;
  v_fail_count integer := 0;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cerebro cotizar test account', v_owner_user)
  RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner_user, 'cc owner', 'cc-owner-' || v_owner_user || '@test.invalid', v_acc, 'owner');
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner_user, '59900243001', 'CC 1', v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_ct, v_acc) RETURNING id INTO v_conv;

  -- Las tasas VIVAS, leidas igual que las leen las cuatro tools originales.
  SELECT t.tasa_cup INTO v_tasa_gyd FROM tasas t WHERE t.moneda = 'gyd'
   ORDER BY t.fecha DESC, t.actualizada_at DESC LIMIT 1;
  SELECT t.tasa_cup INTO v_tasa_usd FROM tasas t WHERE t.moneda = 'usd'
   ORDER BY t.fecha DESC, t.actualizada_at DESC LIMIT 1;
  IF v_tasa_gyd IS NULL OR v_tasa_usd IS NULL THEN
    RAISE EXCEPTION 'cerebro-cotizar: sin tasa viva de gyd (%) o usd (%): no se puede medir paridad',
      v_tasa_gyd, v_tasa_usd;
  END IF;

  -- ---------------------------------------------------------------- case a
  v_esp_destino := round(30000::numeric * v_tasa_gyd);
  v_r := cerebro_cotizar(v_conv, 30000, 'desde_deposito', 'cup', NULL, 'assert-a');
  IF (v_r->>'ok')::boolean
     AND (v_r->>'recibe_monto')::numeric = v_esp_destino
     AND (v_r->>'deposita_gyd')::numeric = 30000
     AND v_r->>'recibe_moneda' = 'CUP'
     AND (v_r->>'tasa')::numeric = v_tasa_gyd THEN
    RAISE NOTICE 'PASS [case a] desde_deposito+cup = calcular_envio (30000 GYD -> % CUP a %)', v_esp_destino, v_tasa_gyd;
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case a] esperaba recibe_monto=% deposita_gyd=30000 tasa=%, llego %', v_esp_destino, v_tasa_gyd, v_r;
  END IF;

  -- ---------------------------------------------------------------- case b
  v_esp_gyd := ceil((100000::numeric / v_tasa_gyd) / 20) * 20;
  v_r := cerebro_cotizar(v_conv, 100000, 'hacia_destino', 'cup', NULL, 'assert-b');
  IF (v_r->>'ok')::boolean
     AND (v_r->>'deposita_gyd')::numeric = v_esp_gyd
     AND (v_r->>'recibe_monto')::numeric = 100000
     AND v_r->>'recibe_moneda' = 'CUP'
     AND v_esp_gyd % 20 = 0 THEN
    RAISE NOTICE 'PASS [case b] hacia_destino+cup = calcular_inverso (100000 CUP <- % GYD, multiplo de 20)', v_esp_gyd;
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case b] esperaba deposita_gyd=% (multiplo de 20) recibe_monto=100000, llego %', v_esp_gyd, v_r;
  END IF;

  -- ---------------------------------------------------------------- case c
  v_usd     := floor(115::numeric);
  v_esp_gyd := round(v_usd * v_tasa_usd);
  v_r := cerebro_cotizar(v_conv, 115, 'hacia_destino', 'usd', 'clasica', 'assert-c');
  IF (v_r->>'ok')::boolean
     AND (v_r->>'recibe_monto')::numeric = v_usd
     AND (v_r->>'deposita_gyd')::numeric = v_esp_gyd
     AND (v_r->>'tasa')::numeric = v_tasa_usd
     AND v_r->>'aplica_a' = 'Clasica/Tropical/Mexico (tasa unica)' THEN
    RAISE NOTICE 'PASS [case c] hacia_destino+usd clasica = calcular_usd tasa unica (115 USD <- % GYD)', v_esp_gyd;
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case c] esperaba recibe_monto=% deposita_gyd=% tasa=%, llego %', v_usd, v_esp_gyd, v_tasa_usd, v_r;
  END IF;

  -- ---------------------------------------------------------------- case d
  v_usd      := floor(115::numeric);
  v_esp_tasa := coalesce(cerebro_tasa_zelle(v_usd), v_tasa_usd);
  v_esp_gyd  := round(v_usd * v_esp_tasa);
  v_r := cerebro_cotizar(v_conv, 115, 'hacia_destino', 'usd', 'zelle', 'assert-d');
  IF (v_r->>'ok')::boolean
     AND (v_r->>'tasa')::numeric = v_esp_tasa
     AND (v_r->>'deposita_gyd')::numeric = v_esp_gyd
     AND v_r->>'aplica_a' = 'Zelle (por tramos)' THEN
    RAISE NOTICE 'PASS [case d] hacia_destino+usd zelle = calcular_usd por tramos (tasa %)', v_esp_tasa;
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case d] esperaba tasa=% deposita_gyd=%, llego %', v_esp_tasa, v_esp_gyd, v_r;
  END IF;

  -- ---------------------------------------------------------------- case e
  v_esp_destino := floor(30000::numeric / v_tasa_usd);
  v_r := cerebro_cotizar(v_conv, 30000, 'desde_deposito', 'usd', 'tropical', 'assert-e');
  IF (v_r->>'ok')::boolean
     AND (v_r->>'recibe_monto')::numeric = v_esp_destino
     AND (v_r->>'deposita_gyd')::numeric = 30000
     AND (v_r->>'tasa')::numeric = v_tasa_usd
     AND (v_r->>'deposita_gyd_exacto')::numeric = round(v_esp_destino * v_tasa_usd) THEN
    RAISE NOTICE 'PASS [case e] desde_deposito+usd tropical = calcular_usd_desde_gyd (30000 GYD -> % USD)', v_esp_destino;
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case e] esperaba recibe_monto=% tasa=%, llego %', v_esp_destino, v_tasa_usd, v_r;
  END IF;

  -- ---------------------------------------------------------------- case f
  SELECT z.usd, z.tasa INTO v_esp_destino, v_esp_tasa FROM cerebro_zelle_cotizar_gyd(30000) z;
  v_esp_tasa    := coalesce(v_esp_tasa, v_tasa_usd);
  v_esp_destino := coalesce(v_esp_destino, floor(30000::numeric / v_tasa_usd));
  v_r := cerebro_cotizar(v_conv, 30000, 'desde_deposito', 'usd', 'zelle', 'assert-f');
  IF (v_r->>'ok')::boolean
     AND (v_r->>'recibe_monto')::numeric = v_esp_destino
     AND (v_r->>'tasa')::numeric = v_esp_tasa THEN
    RAISE NOTICE 'PASS [case f] desde_deposito+usd zelle = calcular_usd_desde_gyd por tramos (% USD a %)', v_esp_destino, v_esp_tasa;
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case f] esperaba recibe_monto=% tasa=%, llego %', v_esp_destino, v_esp_tasa, v_r;
  END IF;

  -- ---------------------------------------------------------------- case g
  -- La etiqueta por direccion es lo que leen la auditoria y cerebro_verificar_coherencia_servicio.
  -- Si la fusion la renombrara, esa red cambiaria de significado sin que nadie lo note.
  IF (cerebro_cotizar(v_conv, 100000, 'hacia_destino', 'cup',  NULL,   'assert-g')->>'herramienta') = 'calcular_inverso'
     AND (cerebro_cotizar(v_conv, 115,   'hacia_destino',  'usd', 'zelle', 'assert-g')->>'herramienta') = 'calcular_usd'
     AND (cerebro_cotizar(v_conv, 30000, 'desde_deposito', 'usd', 'zelle', 'assert-g')->>'herramienta') = 'calcular_usd_desde_gyd' THEN
    RAISE NOTICE 'PASS [case g1] inverso, usd y usd_desde_gyd conservan la etiqueta de su tool original';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case g1] alguna direccion no conserva la etiqueta de su tool original';
  END IF;
  -- esta llamada va ULTIMA entre las de CUP, porque la PK reemplaza la fila de esa moneda
  v_r := cerebro_cotizar(v_conv, 30000, 'desde_deposito', 'cup', NULL, 'assert-g');
  SELECT herramienta INTO v_herr FROM cerebro_ultima_cotizacion
   WHERE conversation_id = v_conv AND destino_moneda = 'CUP';
  IF v_r->>'herramienta' = 'calcular_envio' AND v_herr = 'calcular_envio' THEN
    RAISE NOTICE 'PASS [case g2] cerebro_ultima_cotizacion guarda el nombre de la tool original (calcular_envio)';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case g2] esperaba calcular_envio en el json y en la fila, llego % y %', v_r->>'herramienta', v_herr;
  END IF;

  -- ---------------------------------------------------------------- case h
  -- Primero la prueba de POR QUE: el regex de tasa unica de las tools originales NO empareja
  -- 'efectivo', asi que el efectivo caia en la rama de Zelle y se cotizaba por tramos.
  IF NOT ('efectivo' ~ '^(cl[aá]sica|tropical|m[eé]xico|usdt)') THEN
    RAISE NOTICE 'PASS [case h1] confirmado: el regex original NO empareja efectivo, por eso se colaba como Zelle por tramos';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case h1] el regex original empareja efectivo: la premisa de la divergencia 1 es falsa';
  END IF;
  SELECT count(*), max(herramienta) INTO v_n_antes, v_herr_antes FROM cerebro_ultima_cotizacion
   WHERE conversation_id = v_conv AND destino_moneda = 'USD';
  v_r := cerebro_cotizar(v_conv, 30000, 'desde_deposito', 'usd', 'efectivo', 'assert-h');
  IF NOT (v_r->>'ok')::boolean AND v_r->>'reason' = 'efectivo_tiene_tasa_propia'
     AND v_r->>'usa' LIKE '%efectivo_usd%' THEN
    RAISE NOTICE 'PASS [case h2] efectivo se rechaza y se nombra consultar_servicio(efectivo_usd)';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case h2] esperaba rechazo efectivo_tiene_tasa_propia, llego %', v_r;
  END IF;
  SELECT count(*), max(herramienta) INTO v_n_despues, v_herr
    FROM cerebro_ultima_cotizacion WHERE conversation_id = v_conv AND destino_moneda = 'USD';
  IF v_herr = v_herr_antes AND v_n_despues = v_n_antes THEN
    RAISE NOTICE 'PASS [case h3] el rechazo de efectivo no escribio ninguna cotizacion (sigue %)', v_herr_antes;
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case h3] el rechazo de efectivo cambio la cotizacion: % -> %', v_herr_antes, v_herr;
  END IF;

  -- ---------------------------------------------------------------- case i
  IF NOT (cerebro_cotizar(v_conv, 100, 'cualquiera',     'cup',   NULL, 'assert-i')->>'ok')::boolean
     AND NOT (cerebro_cotizar(v_conv, 100, 'desde_deposito', 'euros', NULL, 'assert-i')->>'ok')::boolean
     AND NOT (cerebro_cotizar(v_conv, 0,   'desde_deposito', 'cup',   NULL, 'assert-i')->>'ok')::boolean
     AND NOT (cerebro_cotizar(v_conv, -5,  'desde_deposito', 'cup',   NULL, 'assert-i')->>'ok')::boolean
     AND NOT (cerebro_cotizar(NULL,   100, 'desde_deposito', 'cup',   NULL, 'assert-i')->>'ok')::boolean THEN
    RAISE NOTICE 'PASS [case i1] direccion y moneda desconocidas, monto no positivo y conversacion nula se rechazan';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case i1] alguna entrada invalida fue aceptada';
  END IF;
  IF (cerebro_cotizar(v_conv, 30000, 'DESDE', 'Pesos',   NULL,    'assert-i')->>'ok')::boolean
     AND (cerebro_cotizar(v_conv, 115, 'hacia', 'dolares', 'ZELLE', 'assert-i')->>'ok')::boolean THEN
    RAISE NOTICE 'PASS [case i2] los alias y las mayusculas se aceptan';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case i2] un alias valido fue rechazado';
  END IF;

  -- ---------------------------------------------------------------- case j
  IF has_function_privilege('service_role', v_sig, 'EXECUTE')
     AND NOT has_function_privilege('anon', v_sig, 'EXECUTE')
     AND NOT has_function_privilege('authenticated', v_sig, 'EXECUTE') THEN
    RAISE NOTICE 'PASS [case j] solo service_role puede ejecutarla';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case j] privilegios inesperados (se espera service_role si, anon y authenticated no)';
  END IF;

  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'cerebro-cotizar: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;
  RAISE NOTICE 'cerebro-cotizar: ALL PASS (13 expectations)';
END $$;

ROLLBACK TO SAVEPOINT cerebro_cotizar;
