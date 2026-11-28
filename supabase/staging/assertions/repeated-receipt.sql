-- =====================================================================
-- Assertion for migration 178 (a repeated receipt is one deposit, never two).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Needs pg_temp.conv_prueba / depositar (split-deposit-minimums.sql).
--
-- Onelsi (2026-09-29, op c31c8b3a): the same MMG receipt (Ref 20401869895051,
-- 5,000 GYD) was sent twice. The Cerebro summed it to 10,000 and the cross
-- failed with "la misma referencia viene repetida" -> incident.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.reenviar(p_conv uuid, p_monto numeric, p_ref text, p_comp text) RETURNS record
LANGUAGE plpgsql AS $$
DECLARE v_reg record; v_cr record; v_out record;
BEGIN
  SELECT * INTO v_reg
    FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref, p_comp) r;
  SELECT * INTO v_cr FROM cerebro_cruzar_depositos(v_reg.deal_id, ARRAY[p_ref], ARRAY[p_monto],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', '3cf01654-cd27-47c1-ac92-62abf5435751');
  SELECT v_reg.deal_id AS deal_id, v_reg.accion AS accion, v_cr.resultado AS resultado INTO v_out;
  RETURN v_out;
END $$;

DO $$
DECLARE
  c_esp CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_conv uuid; v_d1 uuid; v_r record; v_op record; v_n int; v_cr record;
BEGIN
  -- 1. Onelsi: 5,000 to a CUP card, verified; later the same receipt again (another image).
  v_conv := pg_temp.conv_prueba('81', 'cup');
  v_d1 := pg_temp.depositar(v_conv, 5000, '20409990017801', c_esp);
  SELECT * INTO v_r FROM pg_temp.reenviar(v_conv, 5000, '20409990017801', 'COMP-reenvio-81') AS (deal_id uuid, accion text, resultado text);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status <> 'cancelled';
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_n <> 1 OR v_r.deal_id IS DISTINCT FROM v_d1 OR v_op.status <> 'ready_to_transfer'
     OR v_op.quoted_source_amount <> 5000 OR v_r.resultado <> 'verificado' THEN
    RAISE EXCEPTION 'case 1 (resent verified receipt): % ops, same deal %, status %, amount %, cross %, accion %',
      v_n, v_r.deal_id IS NOT DISTINCT FROM v_d1, v_op.status, v_op.quoted_source_amount, v_r.resultado, v_r.accion;
  END IF;
  RAISE NOTICE 'PASS 1: a resent verified receipt changes nothing and still reads verified';

  -- 2. A remesa waiting for the rest (10,000 of a 13,000 Zelle): resending the 10,000 is NOT the rest.
  v_conv := pg_temp.conv_prueba('82', 'zelle');
  v_d1 := pg_temp.depositar(v_conv, 10000, '20409990017802', c_esp);
  SELECT * INTO v_r FROM pg_temp.reenviar(v_conv, 10000, '20409990017802', 'COMP-reenvio-82') AS (deal_id uuid, accion text, resultado text);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status <> 'cancelled';
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_n <> 1 OR v_op.status <> 'deposit_verification' OR v_op.quoted_source_amount <> 10000
     OR v_r.resultado <> 'verificado_incompleto' THEN
    RAISE EXCEPTION 'case 2 (resent part payment): % ops, status %, amount %, cross %, accion %',
      v_n, v_op.status, v_op.quoted_source_amount, v_r.resultado, v_r.accion;
  END IF;
  RAISE NOTICE 'PASS 2: a resent part payment is not summed and the remesa keeps waiting';

  -- 3. Same burst: the same ref and amount twice in the cross is one receipt, not an incident.
  v_conv := pg_temp.conv_prueba('83', 'cup');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en)
  VALUES ('20409990017803', 5000, 'GYD', 'Osmany', 'test178', now());
  SELECT r.deal_id INTO v_d1 FROM cerebro_registrar_deposito(v_conv, 5000, 'GYD', c_esp,
         'DEPOSITO: 5,000 GYD - EXITOSA' || chr(10) || 'Ref: 20409990017803', 'COMP-rafaga-83') r;
  SELECT * INTO v_cr FROM cerebro_cruzar_depositos(v_d1, ARRAY['20409990017803', '20409990017803'], ARRAY[5000, 5000]::numeric[],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_cr.resultado <> 'verificado' OR v_op.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 3 (same ref twice in one burst): cross %, status %', v_cr.resultado, v_op.status;
  END IF;
  RAISE NOTICE 'PASS 3: a receipt repeated inside one burst crosses once';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
