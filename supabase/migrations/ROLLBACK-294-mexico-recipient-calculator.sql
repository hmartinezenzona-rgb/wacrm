-- ROLLBACK 294: restores the 272 body of calculator_service_for_operation.

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
