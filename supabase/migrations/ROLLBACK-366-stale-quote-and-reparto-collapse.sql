-- ROLLBACK for 366: restores the exact bodies that production ran before it (read from production 2026-11-12).

CREATE OR REPLACE FUNCTION public.cerebro_monto_cotizado(p_texto text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH t AS (SELECT lower(coalesce(p_texto, '')) AS s),
  vals AS (
    SELECT DISTINCT replace(m[1], ',', '')::numeric AS gyd
      FROM t, regexp_matches(t.s, 'depositar \*([0-9][0-9,]*) gyd\*', 'g') AS m
    UNION
    SELECT DISTINCT replace(m[1], ',', '')::numeric
      FROM t, regexp_matches(t.s, 'por \*([0-9][0-9,]*) gyd\* (?:le )?llegan \*', 'g') AS m
  )
  SELECT CASE WHEN count(*) = 1 THEN min(gyd) END
    FROM vals, t
   WHERE t.s !~ '(m[ií]nimo|la tasa es \*|tasa se mantiene|a esa tarjeta|a cada|p[aá]gina|per page|hoja)';
$function$;
