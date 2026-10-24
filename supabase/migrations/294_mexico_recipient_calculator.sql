-- =====================================================================
-- 294 -- The calculator knows the Mexico recipient types
--
-- Production 2026-10-24: Mexico operation 4911f4c2 (two mexico_cuenta recipients of 50 USD) was closed and never reached
-- the calculator (calculator_unfed_operations: service_unresolved). calculator_operation_parts counts an unknown
-- beneficiary type through calculator_service_for_operation(b.beneficiary_type), and 272 mapped only 'mexico', not the
-- recipient types 'mexico_cuenta' / 'mexico_retiro' that 271 introduced; with an unknown type it returns NO part at all.
-- A Mexico operation without recipients still resolved through its service_type / delivery_method, which is why 8dd1740c
-- did resolve but 4911f4c2 did not.
--
-- calculator_service_for_operation: 'mexico_cuenta' and 'mexico_retiro' map to CLASICA like 'mexico' (272: single USD
-- rate). Nothing else changes.
-- Assertion: supabase/staging/assertions/mexico-recipient-calculator.sql. Rollback: ROLLBACK-294-*.sql (272 body).
-- =====================================================================

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
           -- (294) the Mexico recipient types of 271 resolve the same way.
           WHEN 'mexico_cuenta'         THEN 'CLASICA'
           WHEN 'mexico_retiro'         THEN 'CLASICA'
           -- (223) A mobile balance (service_type; its recipient row is typed 'recarga' and maps to RECARGA on its own).
           WHEN 'saldo'                 THEN 'SALDO_MOVIL'
           ELSE NULL
         END;
$function$;
