-- =====================================================================
-- Assertion for migration 207 (a recharge opens only with a running or confirmed upcoming promo). Self-reverting:
-- one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- Owner, 2026-10-04: with no promo the bot must not open a recharge or ask for the number. Amended the same day: the
-- admins often take the numbers before a confirmed promo starts (the customer pays then or on the day), so with a
-- confirmed upcoming promo the recharge opens, booked for the start date.
-- =====================================================================
DO $$
DECLARE
  v_hoy  date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_conv uuid;
  v_user uuid;
  v_acc  uuid;
  v_ct   uuid;
  v_res  text;
  v_hechos text;
BEGIN
  -- A fresh conversation of the business account (staging can have none after a reset).
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990020701', 'test207') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  -- No promo running; one confirmed upcoming promo.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy + 4, v_hoy + 7, 'ASSERT PROXIMA', 'https://assert.invalid/p', 'assert', md5('assert-proxima-207'), 'confirmada');

  -- 1. Confirmed upcoming promo: the recharge opens with the number, booked for the start date (the reply says so).
  v_res := crm_registrar_numeros_recarga(v_conv, 'recarga al 52345678', true);
  IF v_res NOT LIKE 'guardados 1 %' OR v_res NOT LIKE '%ANOTADA PARA EL ' || to_char(v_hoy + 4, 'DD/MM') || '%' THEN
    RAISE EXCEPTION 'case 1: got %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_operations o JOIN remittance_beneficiaries b ON b.operation_id = o.id
                  WHERE o.conversation_id = v_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
                    AND b.phone = '52345678' AND b.status = 'vigente') THEN
    RAISE EXCEPTION 'case 1: the upcoming promo did not open the recharge with its number'; END IF;
  UPDATE remittance_operations SET status = 'cancelled'
   WHERE conversation_id = v_conv AND service_type = 'recarga' AND status NOT IN ('completed', 'cancelled');

  -- 2. What the bot reads about the upcoming promo: it may book it now, payment now or on the day, never done before.
  SELECT hechos INTO v_hechos FROM cerebro_servicio_get('recargas');
  IF v_hechos NOT LIKE '%se puede dejar ANOTADA desde ya%' OR v_hechos LIKE '%No cobres recargas hasta esa fecha%' THEN
    RAISE EXCEPTION 'case 2: hechos = %', right(v_hechos, 500); END IF;

  -- 3. No promo at all: nothing opens, nothing is saved, and the reply says to offer an operator.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE huella = md5('assert-proxima-207');
  v_res := crm_registrar_numeros_recarga(v_conv, 'recarga al 52345678', true);
  IF v_res NOT LIKE 'NO HAY PROMOCION DE ETECSA%' OR v_res NOT LIKE '%operador%' THEN
    RAISE EXCEPTION 'case 3: got %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'recarga'
                AND status NOT IN ('completed', 'cancelled')) THEN
    RAISE EXCEPTION 'case 3: a recharge was opened with no promo'; END IF;

  -- 4. A promo running today: the recharge opens and keeps the number, as before.
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-207'), 'confirmada');
  v_res := crm_registrar_numeros_recarga(v_conv, 'recarga al 52345678', true);
  IF v_res NOT LIKE 'guardados 1 %' THEN
    RAISE EXCEPTION 'case 4: got %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_operations o JOIN remittance_beneficiaries b ON b.operation_id = o.id
                  WHERE o.conversation_id = v_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
                    AND b.phone = '52345678' AND b.status = 'vigente') THEN
    RAISE EXCEPTION 'case 4: the running promo did not open the recharge with its number'; END IF;

  RAISE EXCEPTION 'ALL PASS';
END $$;
