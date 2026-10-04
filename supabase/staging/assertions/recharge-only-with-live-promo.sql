-- =====================================================================
-- Assertion for migration 207 (a recharge opens only while a promo is running). Self-reverting: one DO block that
-- ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- Owner test, 2026-10-04: with the promo starting on the 8th, a customer who asked on the 4th got a recharge opened
-- and was asked for the Cuban number.
-- =====================================================================
DO $$
DECLARE
  v_hoy  date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_conv uuid;
  v_res  text;
  v_hechos text;
BEGIN
  -- Any conversation with no open recharge; its open recharges (if any) are cancelled inside this block only.
  SELECT id INTO v_conv FROM conversations ORDER BY created_at DESC LIMIT 1;
  UPDATE remittance_operations SET status = 'cancelled'
   WHERE conversation_id = v_conv AND service_type = 'recarga' AND status NOT IN ('completed', 'cancelled');
  -- No promo running; one confirmed upcoming promo.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy + 4, v_hoy + 7, 'ASSERT PROXIMA', 'https://assert.invalid/p', 'assert', md5('assert-proxima-207'), 'confirmada');

  -- 1. Upcoming promo only: nothing opens, nothing is saved, and the reply carries the start date.
  v_res := crm_registrar_numeros_recarga(v_conv, 'recarga al 52345678', true);
  IF v_res NOT LIKE 'NO HAY PROMOCION VIGENTE HOY%' OR v_res NOT LIKE '%' || to_char(v_hoy + 4, 'DD/MM') || '%' THEN
    RAISE EXCEPTION 'case 1: got %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'recarga'
                AND status NOT IN ('completed', 'cancelled')) THEN
    RAISE EXCEPTION 'case 1: a recharge was opened before the promo'; END IF;

  -- 2. What the bot reads about the upcoming promo forbids asking for the number.
  SELECT hechos INTO v_hechos FROM cerebro_servicio_get('recargas');
  IF v_hechos NOT LIKE '%PROHIBIDO pedir el numero de Cuba%' THEN
    RAISE EXCEPTION 'case 2: hechos = %', right(v_hechos, 400); END IF;

  -- 3. No promo at all: nothing opens, and the reply says to offer an operator.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE huella = md5('assert-proxima-207');
  v_res := crm_registrar_numeros_recarga(v_conv, 'recarga al 52345678', true);
  IF v_res NOT LIKE 'NO HAY PROMOCION VIGENTE HOY%' OR v_res NOT LIKE '%operador%' THEN
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
