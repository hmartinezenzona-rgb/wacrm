-- ROLLBACK for 122_promo_dia_guyana.sql: restores the 047/049 zero-argument
-- versions (UTC current_date) exactly as they were in production on 2026-09-25.
DROP FUNCTION IF EXISTS public.cerebro_promo_vigente(date);
DROP FUNCTION IF EXISTS public.cerebro_promo_proxima(date);

CREATE FUNCTION public.cerebro_promo_vigente()
RETURNS TABLE(min_cup numeric, max_cup numeric, multiplicador numeric, precio_gyd numeric,
              vigente_hasta date, estado text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT p.min_cup, p.max_cup, p.multiplicador, r.precio_gyd, p.vigente_hasta, p.estado
    FROM promo_etecsa p
    JOIN precio_recarga r ON r.min_cup = p.min_cup
   WHERE current_date BETWEEN p.vigente_desde AND p.vigente_hasta
     AND (p.estado = 'confirmada'
          OR (p.estado = 'detectada'
              AND coalesce(cerebro_config_get('promo_etecsa_modo'),'confirmar') = 'automatico'))
   ORDER BY p.confirmada_at DESC NULLS LAST, p.detectada_at DESC
   LIMIT 1;
$function$;

CREATE FUNCTION public.cerebro_promo_proxima()
RETURNS TABLE(min_cup numeric, max_cup numeric, multiplicador numeric, precio_gyd numeric,
              vigente_desde date, vigente_hasta date, dias_para integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT p.min_cup, p.max_cup, p.multiplicador, r.precio_gyd,
         p.vigente_desde, p.vigente_hasta,
         (p.vigente_desde - current_date)::int AS dias_para
    FROM promo_etecsa p
    JOIN precio_recarga r ON r.min_cup = p.min_cup
   WHERE p.vigente_desde > current_date
     AND p.vigente_desde <= current_date
         + (coalesce(cerebro_config_get('promo_etecsa_avisar_dias_antes'),'7'))::int
     AND (p.estado = 'confirmada'
          OR (p.estado = 'detectada'
              AND coalesce(cerebro_config_get('promo_etecsa_modo'),'confirmar') = 'automatico'))
   ORDER BY p.vigente_desde
   LIMIT 1;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_promo_vigente() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_promo_proxima() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_promo_vigente() TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_promo_proxima() TO service_role;
