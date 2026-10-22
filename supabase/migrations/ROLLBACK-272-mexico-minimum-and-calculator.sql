-- ROLLBACK of 272_mexico_minimum_and_calculator.sql: restores the four functions exactly as before 272
-- (pg_get_functiondef md5 on staging, 2026-10-22: cerebro_minimo_gyd c2c4462d5ccb233f0a97adae77121597, cerebro_dashboard_historial 7aaca192156d2d514b3a31a3e3b5fc4b, calculator_service_for_operation 7f2cde558c25aecbb9692e34361b3f1c, calculator_resolve_operation_service ea1808db617f00597c9852b9907aca7c).
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

CREATE OR REPLACE FUNCTION public.cerebro_dashboard_historial(p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_servicio text DEFAULT NULL::text, p_limite integer DEFAULT 200, p_desde_fila integer DEFAULT 0)
 RETURNS TABLE(dia date, service_type text, status text, cliente text, telefono text, monto_gyd numeric, beneficiario text, tarjeta text, operation_id uuid, total bigint, servicio text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH base AS (
    SELECT h.dia, h.service_type, h.status, h.cliente, h.telefono,
           h.monto_gyd, h.beneficiario, h.tarjeta, h.operation_id
      FROM cerebro_historial_operaciones h
     WHERE (p_desde IS NULL OR h.dia >= p_desde)
       AND (p_hasta IS NULL OR h.dia <= p_hasta)
  ),
  -- (229) The ledger-style service, once per operation (not per recipient row).
  svc AS (
    SELECT o.id AS operation_id,
           coalesce(
             calculator_resolve_operation_service(o.id, o.delivery_method),
             CASE WHEN o.service_type = 'remesa'
                   AND (lower(coalesce(o.delivery_method, '')) = 'multiple_distribution'
                        OR (SELECT count(DISTINCT b.beneficiary_type)
                              FROM remittance_beneficiaries b
                             WHERE b.operation_id = o.id AND b.status = 'vigente') > 1)
                  THEN 'MIXTA'
                  ELSE upper(o.service_type)
             END) AS servicio
      FROM remittance_operations o
     WHERE o.id IN (SELECT DISTINCT x.operation_id FROM base x)
  ),
  filtrado AS (
    SELECT b.*, s.servicio
      FROM base b
      JOIN svc s ON s.operation_id = b.operation_id
     WHERE p_servicio IS NULL
        OR b.service_type = p_servicio
        OR upper(s.servicio) = upper(p_servicio)
  )
  SELECT f.dia, f.service_type, f.status, f.cliente, f.telefono,
         f.monto_gyd, f.beneficiario, f.tarjeta, f.operation_id,
         count(*) OVER () AS total, f.servicio
    FROM filtrado f
   ORDER BY f.dia DESC, f.monto_gyd DESC, f.operation_id,
            f.tarjeta NULLS LAST, f.beneficiario NULLS LAST
   LIMIT  least(coalesce(p_limite, 200), 1000)
  OFFSET greatest(coalesce(p_desde_fila, 0), 0);
$function$;

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
