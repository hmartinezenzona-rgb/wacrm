-- ROLLBACK of 234_resumen_from_ledger.sql: restores cerebro_dashboard_resumen exactly as staging and production had it on 2026-10-08
-- (pg_get_functiondef md5 84ba499d6e5e0ad876cc0ebc11b1eb28; migration 055 body: it reads cerebro_resumen_volumen, which this migration never touched).
-- The grants are kept by CREATE OR REPLACE. No BEGIN/COMMIT.

CREATE OR REPLACE FUNCTION public.cerebro_dashboard_resumen()
 RETURNS TABLE(orden integer, periodo text, desde date, hasta date, operaciones bigint, volumen_gyd numeric, ticket_medio_gyd numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT r.orden, r.periodo, r.desde, r.hasta,
         r.operaciones, r.volumen_gyd, r.ticket_medio_gyd
    FROM cerebro_resumen_volumen r ORDER BY r.orden;
$function$;
