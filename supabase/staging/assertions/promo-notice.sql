-- =====================================================================
-- Assertion for migration 206 (ETECSA promo notice). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- Owner, 2026-10-04: the monitor's notice must reach the business admins (on any environment, including new
-- admins), and a promo that has already ended must not be registered or notified.
-- =====================================================================
DO $$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_account uuid;
  v_admins uuid[];
  v_res text;
  v_n int;
  v_users uuid[];
BEGIN
  SELECT account_id INTO v_account FROM whatsapp_config LIMIT 1;
  SELECT array_agg(user_id ORDER BY user_id) INTO v_admins
    FROM profiles WHERE account_id = v_account AND account_role IN ('owner', 'admin');
  IF v_account IS NULL OR coalesce(cardinality(v_admins), 0) = 0 THEN
    RAISE EXCEPTION 'setup: no business account or no owner/admin (account %)', v_account; END IF;
  -- Other promos (real or left over from staging tests) must not compete with the ones registered here.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');

  -- 1. An upcoming promo is registered and notifies exactly the business owner and admins.
  v_res := cerebro_promo_revision(jsonb_build_object(
    'ok', true, 'min_cup', 600, 'max_cup', 1250, 'multiplicador', 97,
    'desde', v_hoy + 5, 'hasta', v_hoy + 8, 'titulo', 'ASSERT PROMO FUTURA', 'url', 'https://assert.invalid/futura',
    'texto', 'assert'));
  IF v_res IS DISTINCT FROM 'detectada, pendiente de confirmar' THEN
    RAISE EXCEPTION 'case 1: got %', v_res; END IF;
  SELECT array_agg(user_id ORDER BY user_id), count(*) INTO v_users, v_n
    FROM notifications WHERE type = 'promo_etecsa' AND body LIKE '%x97,%' AND account_id = v_account;
  IF v_users IS DISTINCT FROM v_admins THEN
    RAISE EXCEPTION 'case 1: notified % (count %), expected %', v_users, v_n, v_admins; END IF;

  -- 2. A promo that has already ended is neither registered nor notified.
  v_res := cerebro_promo_revision(jsonb_build_object(
    'ok', true, 'min_cup', 600, 'max_cup', 1250, 'multiplicador', 98,
    'desde', v_hoy - 6, 'hasta', v_hoy - 1, 'titulo', 'ASSERT PROMO VIEJA', 'url', 'https://assert.invalid/vieja',
    'texto', 'assert'));
  IF v_res IS DISTINCT FROM 'ya terminada, no se avisa' THEN
    RAISE EXCEPTION 'case 2: got %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM promo_etecsa WHERE multiplicador = 98)
     OR EXISTS (SELECT 1 FROM notifications WHERE type = 'promo_etecsa' AND body LIKE '%x98,%') THEN
    RAISE EXCEPTION 'case 2: the ended promo was registered or notified'; END IF;

  -- 3. A promo running today (ends today) is still registered and notified.
  v_res := cerebro_promo_revision(jsonb_build_object(
    'ok', true, 'min_cup', 600, 'max_cup', 1250, 'multiplicador', 99,
    'desde', v_hoy - 2, 'hasta', v_hoy, 'titulo', 'ASSERT PROMO HOY', 'url', 'https://assert.invalid/hoy',
    'texto', 'assert'));
  IF v_res IS DISTINCT FROM 'detectada, pendiente de confirmar' THEN
    RAISE EXCEPTION 'case 3: got %', v_res; END IF;

  -- 4. Once confirmed, the upcoming promo is what the bot announces.
  PERFORM cerebro_promo_confirmar(id, 'assert') FROM promo_etecsa WHERE multiplicador = 97;
  IF NOT EXISTS (SELECT 1 FROM cerebro_promo_proxima(v_hoy) WHERE multiplicador = 97) THEN
    RAISE EXCEPTION 'case 4: the confirmed upcoming promo is not the next one'; END IF;

  RAISE EXCEPTION 'ALL PASS';
END $$;
