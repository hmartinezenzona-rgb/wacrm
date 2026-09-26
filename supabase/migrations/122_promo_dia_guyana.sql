-- =====================================================================
-- 122 — Promo validity follows the Guyana day
--
-- WHY
--   cerebro_promo_vigente() and cerebro_promo_proxima() (047, 049) compare
--   against `current_date`, which in this database (TimeZone = UTC) turns
--   over at 20:00 Guyana. A promo therefore started and ended four hours
--   early: from 20:00 on its last day the bot already said "no promotion",
--   and from 20:00 the evening before it was already quoting it.
--
-- WHAT
--   Both functions take `p_hoy date DEFAULT (now() AT TIME ZONE
--   'America/Guyana')::date` — the Guyana calendar day unless a caller
--   (the assertions) passes one. The zero-argument versions are DROPPED
--   first: keeping them next to the new ones would make the no-argument
--   call in cerebro_servicio_get ambiguous. The bodies are otherwise the
--   047/049 ones unchanged. cerebro_servicio_get (the only caller, a SQL
--   function) needs no change.
--
-- GRANTS
--   Same as today (064): nothing for PUBLIC/anon/authenticated; the n8n
--   Postgres credential and service_role keep EXECUTE.
--
-- TESTS: supabase/staging/assertions/promo-guyana-date.sql (rolled back).
-- ROLLBACK: ROLLBACK-122-promo-dia-guyana.sql
-- =====================================================================

DROP FUNCTION IF EXISTS public.cerebro_promo_vigente();
DROP FUNCTION IF EXISTS public.cerebro_promo_proxima();

CREATE FUNCTION public.cerebro_promo_vigente(
  p_hoy date DEFAULT (now() AT TIME ZONE 'America/Guyana')::date
)
RETURNS TABLE(min_cup numeric, max_cup numeric, multiplicador numeric, precio_gyd numeric,
              vigente_hasta date, estado text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT p.min_cup, p.max_cup, p.multiplicador, r.precio_gyd, p.vigente_hasta, p.estado
    FROM promo_etecsa p
    JOIN precio_recarga r ON r.min_cup = p.min_cup
   WHERE p_hoy BETWEEN p.vigente_desde AND p.vigente_hasta
     AND (p.estado = 'confirmada'
          OR (p.estado = 'detectada'
              AND coalesce(cerebro_config_get('promo_etecsa_modo'),'confirmar') = 'automatico'))
   ORDER BY p.confirmada_at DESC NULLS LAST, p.detectada_at DESC
   LIMIT 1;
$function$;

CREATE FUNCTION public.cerebro_promo_proxima(
  p_hoy date DEFAULT (now() AT TIME ZONE 'America/Guyana')::date
)
RETURNS TABLE(min_cup numeric, max_cup numeric, multiplicador numeric, precio_gyd numeric,
              vigente_desde date, vigente_hasta date, dias_para integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT p.min_cup, p.max_cup, p.multiplicador, r.precio_gyd,
         p.vigente_desde, p.vigente_hasta,
         (p.vigente_desde - p_hoy)::int AS dias_para
    FROM promo_etecsa p
    JOIN precio_recarga r ON r.min_cup = p.min_cup
   WHERE p.vigente_desde > p_hoy
     AND p.vigente_desde <= p_hoy
         + (coalesce(cerebro_config_get('promo_etecsa_avisar_dias_antes'),'7'))::int
     AND (p.estado = 'confirmada'
          OR (p.estado = 'detectada'
              AND coalesce(cerebro_config_get('promo_etecsa_modo'),'confirmar') = 'automatico'))
   ORDER BY p.vigente_desde
   LIMIT 1;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_promo_vigente(date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_promo_proxima(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_promo_vigente(date) TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_promo_proxima(date) TO service_role;
