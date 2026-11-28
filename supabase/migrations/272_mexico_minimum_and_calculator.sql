-- 272: Mexico as a real operation, money side (M3). Staging first; apply after 271.
--
-- Business (owner 2026-10-22): Mexico is sold at the single USD rate (260 GYD per USD), minimum 13,000 GYD (50 USD), no maximum.
-- The payout in MXN is set by the operator on the day and is NOT stored. The cost of a send is UNKNOWN.
--
-- Changes (four functions, each a CREATE OR REPLACE of the live body plus one branch; signatures and ACLs unchanged):
--   cerebro_minimo_gyd(uuid)                           service_type 'mexico' -> config minimo_gyd_mexico, default 13,000
--                                                      (was the CUP ELSE, 5,000). Read from the service_type because a Mexico
--                                                      operation has no rail of its own (cerebro_riel_op is left alone).
--   calculator_service_for_operation(text)             'mexico' -> 'CLASICA'
--   calculator_resolve_operation_service(uuid, text)   service_type 'mexico' -> 'CLASICA' before the row/rail logic
--   cerebro_dashboard_historial(date,date,text,int,int) a Mexico operation keeps the history label MEXICO (229 took the label
--                                                      from calculator_resolve_operation_service, which now says CLASICA)
--
-- Why CLASICA and not a new 'MEXICO' service: the ledger CHECK (213), the feed, calculator_missing_rates, the manual-entry
-- lists (228/237/242) and the inventory list (240) only know the existing services. CLASICA is already the single-USD-rate
-- service (ledger line in USD, sold at usdt_sell_gyd, rates asked: usdt_buy_gyd and usdt_sell_gyd). Tradeoff: Mexico lines
-- read as CLASICA in the ledger; telling them apart needs a later 'MEXICO' service (CHECK + feed + lists).
--
-- Cost per send: NOT invented. The ledger keeps its behaviour for every USD service: invertido = USD amount x usdt_buy_gyd
-- (what the dollars cost), retorno = facturado - invertido. No fee or per-send cost is subtracted; when Osmany gives it, add
-- a config key and a branch here. Not touched: the inline minimums of cerebro_declarar_servicio / cerebro_resolver_servicio
-- (265) are 273 / M4's.
--
-- Guard: only adds a 'mexico' branch to each function; no data is touched. Rollback restores the previous bodies
-- (md5 on staging 2026-10-22, see ROLLBACK-272).

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
    -- (272) Mexico: 13,000 GYD (50 USD at 260). Read from the service_type, not the rail: a Mexico operation has no rail of
    -- its own and its rail-less / stale delivery_method would fall to the CUP ELSE (5,000).
    WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_op) = 'mexico'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_mexico'), '')::numeric, 13000)
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
             -- (272) A Mexico operation keeps its own history label (MEXICO) although the calculator now prices it as CLASICA.
             CASE WHEN o.service_type = 'mexico' THEN 'MEXICO'
                  ELSE calculator_resolve_operation_service(o.id, o.delivery_method) END,
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
           -- (272) Mexico is priced at the single USD rate, like Clasica / Tropical: it reuses CLASICA (the ledger CHECK, the
           -- feed, the missing-rates and the manual-entry lists know no 'MEXICO' service). Cost per send: unknown, not modelled.
           WHEN 'mexico'                THEN 'CLASICA'
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
           -- (272) A Mexico operation is priced at the single USD rate (CLASICA) whatever its rows or a stale rail say.
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'mexico' THEN 'CLASICA'
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
