\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 349 (Etecsa watcher fails loud). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Runs on staging and production.
--
-- Owner, 2026-10-28: a failed read of etecsa.cu must not count as a check, and the admins are told once.
-- Cases:
--   1. leida=false: the last-good-check mark does not move; the failure is recorded with its error.
--   2. leida=false: exactly the business owner and admins get one notice.
--   3. A second failure in the same streak notifies nobody again.
--   4. leida=true: the mark moves (a good read), and a later failure notifies again (new streak).
--   5. No `leida` key: previous behaviour (the mark moves, "revision hecha, sin promocion legible").
-- =====================================================================
DO $$
DECLARE
  v_account uuid;
  v_admins uuid[];
  v_users uuid[];
  v_marca text;
  v_res text;
  v_n int;
  v_fallos int := 0;
BEGIN
  SELECT account_id INTO v_account FROM whatsapp_config LIMIT 1;
  SELECT array_agg(user_id ORDER BY user_id) INTO v_admins
    FROM profiles WHERE account_id = v_account AND account_role IN ('owner', 'admin');
  IF v_account IS NULL OR coalesce(cardinality(v_admins), 0) = 0 THEN
    RAISE EXCEPTION 'setup: no business account or no owner/admin (account %)', v_account; END IF;

  -- Known starting point: a good read two days ago and no failure notice after it.
  INSERT INTO cerebro_config (clave, valor, descripcion)
  VALUES ('promo_etecsa_ultima_revision', (now() - interval '2 days')::text, 'assert')
  ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;
  DELETE FROM notifications WHERE type = 'promo_etecsa' AND title = 'No se pudo revisar la web de Etecsa';
  SELECT valor INTO v_marca FROM cerebro_config WHERE clave = 'promo_etecsa_ultima_revision';

  -- 1. A failed read does not move the mark and records the error.
  v_res := cerebro_promo_revision(jsonb_build_object('ok', false, 'leida', false,
             'error', 'connect ECONNREFUSED 190.92.127.202:443'));
  IF v_res IS DISTINCT FROM 'fallo de lectura, avisado: connect ECONNREFUSED 190.92.127.202:443' THEN
    RAISE WARNING 'case 1: got %', v_res; v_fallos := v_fallos + 1; END IF;
  IF (SELECT valor FROM cerebro_config WHERE clave = 'promo_etecsa_ultima_revision') IS DISTINCT FROM v_marca THEN
    RAISE WARNING 'case 1: the last-good-check mark moved on a failed read'; v_fallos := v_fallos + 1; END IF;
  IF NOT EXISTS (SELECT 1 FROM cerebro_config WHERE clave = 'promo_etecsa_ultimo_fallo'
                  AND valor LIKE '%ECONNREFUSED%') THEN
    RAISE WARNING 'case 1: the failure was not recorded'; v_fallos := v_fallos + 1; END IF;

  -- 2. Exactly the owner and admins are notified, once.
  SELECT array_agg(user_id ORDER BY user_id) INTO v_users
    FROM notifications WHERE type = 'promo_etecsa' AND title = 'No se pudo revisar la web de Etecsa'
     AND account_id = v_account;
  IF v_users IS DISTINCT FROM v_admins THEN
    RAISE WARNING 'case 2: notified %, expected %', v_users, v_admins; v_fallos := v_fallos + 1; END IF;

  -- 3. A second failure in the same streak notifies nobody again.
  v_res := cerebro_promo_revision(jsonb_build_object('ok', false, 'leida', false, 'error', 'timeout'));
  SELECT count(*) INTO v_n FROM notifications
   WHERE type = 'promo_etecsa' AND title = 'No se pudo revisar la web de Etecsa';
  IF v_res IS DISTINCT FROM 'fallo de lectura, ya avisado: timeout' OR v_n <> cardinality(v_admins) THEN
    RAISE WARNING 'case 3: got % with % notices', v_res, v_n; v_fallos := v_fallos + 1; END IF;

  -- 4. A good read moves the mark; a later failure starts a new streak and notifies again.
  v_res := cerebro_promo_revision(jsonb_build_object('ok', false, 'leida', true));
  IF v_res IS DISTINCT FROM 'revision hecha, sin promocion legible'
     OR (SELECT valor FROM cerebro_config WHERE clave = 'promo_etecsa_ultima_revision') = v_marca THEN
    RAISE WARNING 'case 4: good read got % and the mark did not move', v_res; v_fallos := v_fallos + 1; END IF;
  -- now() is fixed inside the transaction: date the earlier notices before the new mark.
  UPDATE notifications SET created_at = now() - interval '1 day'
   WHERE type = 'promo_etecsa' AND title = 'No se pudo revisar la web de Etecsa';
  v_res := cerebro_promo_revision(jsonb_build_object('ok', false, 'leida', false, 'error', 'otra vez'));
  SELECT count(*) INTO v_n FROM notifications
   WHERE type = 'promo_etecsa' AND title = 'No se pudo revisar la web de Etecsa';
  IF v_res IS DISTINCT FROM 'fallo de lectura, avisado: otra vez' OR v_n <> 2 * cardinality(v_admins) THEN
    RAISE WARNING 'case 4: new streak got % with % notices', v_res, v_n; v_fallos := v_fallos + 1; END IF;

  -- 5. Without `leida`, the previous behaviour.
  UPDATE cerebro_config SET valor = v_marca WHERE clave = 'promo_etecsa_ultima_revision';
  v_res := cerebro_promo_revision(jsonb_build_object('ok', false));
  IF v_res IS DISTINCT FROM 'revision hecha, sin promocion legible'
     OR (SELECT valor FROM cerebro_config WHERE clave = 'promo_etecsa_ultima_revision') = v_marca THEN
    RAISE WARNING 'case 5: got %, mark moved: %', v_res,
      (SELECT valor FROM cerebro_config WHERE clave = 'promo_etecsa_ultima_revision') <> v_marca;
    v_fallos := v_fallos + 1; END IF;

  IF v_fallos > 0 THEN RAISE EXCEPTION 'FAILED: % expectation(s)', v_fallos; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
