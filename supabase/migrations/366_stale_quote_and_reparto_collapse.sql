-- 366: the agreed amount follows the bot's latest quote, and a reparto collapsed to one card leaves no empty recipient.
--
-- Incident 2026-11-12 (conversation 29597f4b, operation af44d909):
--   A. The bot quoted "Por *5,000 GYD* llegan *18,000 CUP*" and later re-quoted "Con *10,000 GYD* salen *36,000 CUP*:
--      *18,000 CUP* para cada tarjeta." and "Sí, los *10,000 GYD* quedan completos en esa misma tarjeta: *36,000 CUP*.".
--      cerebro_monto_cotizado (171) only knew "depositar *X gyd*" and "por *X gyd* (le )llegan *", and its exclusion
--      "a cada" (per-card share notice) also matched "par[a cada] tarjeta", so neither re-quote was recorded: the 5,000
--      quote stayed vigente and a correct 10,000 GYD deposit was reported as "5,000 more than agreed".
--   B. (second part of this migration, cerebro_guardar_reparto.)
--
-- Part A: two new quote phrasings ("con *X gyd* (le )salen|llegan *", "los *X gyd* quedan completos") and the per-card
-- exclusion "a cada" now needs a word boundary before it (\ma cada), so "para cada tarjeta" no longer excludes a quote while
-- "a cada tarjeta" (the share of ONE card, requested-amount-target case 4) still does. Every other exclusion is unchanged.
-- Rollback: ROLLBACK-366-stale-quote-and-reparto-collapse.sql.

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
    UNION
    SELECT DISTINCT replace(m[1], ',', '')::numeric
      FROM t, regexp_matches(t.s, 'con \*([0-9][0-9,]*) gyd\* (?:le )?(?:salen|llegan) \*', 'g') AS m
    UNION
    SELECT DISTINCT replace(m[1], ',', '')::numeric
      FROM t, regexp_matches(t.s, 'los \*([0-9][0-9,]*) gyd\* quedan completos', 'g') AS m
  )
  SELECT CASE WHEN count(*) = 1 THEN min(gyd) END
    FROM vals, t
   WHERE t.s !~ '(m[ií]nimo|la tasa es \*|tasa se mantiene|a esa tarjeta|\ma cada|p[aá]gina|per page|hoja)';
$function$;
