-- ROLLBACK of 272_mexico_minimum_and_calculator.sql: restores the three functions exactly as before 272
-- (pg_get_functiondef md5 on staging, 2026-10-22: cerebro_minimo_gyd c2c4462d5ccb233f0a97adae77121597, calculator_service_for_operation 7f2cde558c25aecbb9692e34361b3f1c, calculator_resolve_operation_service ea1808db617f00597c9852b9907aca7c).
-- Signatures, volatility and ACLs are unchanged by 272, so nothing else is needed. No data is touched.

CREATE OR REPLACE FUNCTION public.cerebro_minimo_gyd(p_op uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_riel text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = p_op) THEN RETURN NULL; END IF;
  v_riel := cerebro_riel_op(p_op);
  RETURN CASE
    WHEN v_riel = 'recarga'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200)
    -- (209) A combo: 25,000 GYD per recipient (at least one).
    WHEN v_riel = 'combo'
      THEN 25000 * greatest(1, (SELECT count(*) FROM remittance_beneficiaries b
                                 WHERE b.operation_id = p_op AND b.status = 'vigente'))
    -- (213) A visa extension: 5,000 GYD per person (the deposit says how many).
    WHEN v_riel = 'visa' THEN 5000
    -- (223) A mobile balance: one package (precio_saldo_gyd, 1,000 GYD).
    WHEN v_riel = 'saldo' THEN cerebro_saldo_precio()
    WHEN v_riel IN ('zelle', 'clasica', 'tropical')
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'efectivo_usd'
      THEN cerebro_minimo_efectivo_gyd()  -- (188) 100 USD x the calculator cash rate
    ELSE COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000)
  END;
END $function$;

CREATE OR REPLACE FUNCTION public.calculator_service_for_operation(p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE lower(coalesce(p_delivery_method, ''))
           WHEN 'cuban_card'            THEN 'CUP'
           WHEN 'multiple_distribution' THEN 'CUP'
           WHEN 'zelle'                 THEN 'ZELLE'
           WHEN 'clasica'               THEN 'CLASICA'
           WHEN 'tropical'              THEN 'TROPICAL'
           -- (193) Cash dollars delivered in Cuba: their own service, priced at the cash sale rate.
           WHEN 'efectivo_usd'          THEN 'EFECTIVO'
           -- (199) A beneficiary row of a recharge (one Cuban number per recharge).
           WHEN 'recarga'               THEN 'RECARGA'
           -- (209) A combo (its beneficiary rows are typed 'combo' and so is its service_type).
           WHEN 'combo'                 THEN 'COMBO'
           -- (213) A visa extension (no beneficiary rows: its service_type is the only signal).
           WHEN 'visa'                  THEN 'VISA'
           -- (223) A mobile balance (service_type; its recipient row is typed 'recarga' and maps to RECARGA on its own).
           WHEN 'saldo'                 THEN 'SALDO_MOVIL'
           ELSE NULL
         END;
$function$;

CREATE OR REPLACE FUNCTION public.calculator_resolve_operation_service(p_operation_id uuid, p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
           -- (199) A recharge is priced as RECARGA whatever its rows say (even with no number yet).
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'recarga' THEN 'RECARGA'
           -- (209) A combo is priced as COMBO whatever its rows say.
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'combo' THEN 'COMBO'
           -- (213) A visa is priced as VISA (it has no rows at all).
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'visa' THEN 'VISA'
           -- (223) A mobile balance is priced as SALDO_MOVIL whatever its rows say (its phone row is typed 'recarga').
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'saldo' THEN 'SALDO_MOVIL'
           WHEN NOT EXISTS (
             SELECT 1 FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) THEN calculator_service_for_operation(p_delivery_method)
           WHEN (
             SELECT count(DISTINCT b.beneficiary_type)
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) = 1 THEN calculator_service_for_operation((
             SELECT b.beneficiary_type
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
              LIMIT 1
           ))
           ELSE NULL
         END;
$function$;
