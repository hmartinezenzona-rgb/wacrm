-- =====================================================================
-- 195 — An ID card counts as the cash recipient's only when the names match (staging first)
--
-- odd/tasks/remesa-closing-and-cash.md. Owner test on staging, 2026-10-03 18:29 UTC: the customer sent an ID in another
-- person's name; the bot noticed and asked for the right one, but 'Registrar carnet efectivo' had already stored the
-- photo. Owner: such an ID is NOT stored until the right one arrives. cerebro_nombre_coincide(id_name, recipient_name)
-- is used by that node (Cerebro, gate90) when both names are known.
-- Vision reads names imperfectly ("FRENE VERA ANABEL" for "Anabel Frenes Vera"), so: lower case, no accents, any order;
-- two words match when equal or one edit apart (substitution, insertion or deletion), words of 3+ letters; it matches
-- when at least 2 words of the recipient's name match (or its only word). No extension needed (none is installed).
--
-- Guarded by supabase/staging/assertions/id-name-match.sql.
-- ROLLBACK: ROLLBACK-195-id-name-match.sql
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cerebro_palabras_nombre(p text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT coalesce(array_agg(w), ARRAY[]::text[])
    FROM regexp_split_to_table(
           translate(lower(coalesce(p, '')), 'áéíóúüñàèìòùâêîôûäëïöç', 'aeiouunaeiouaeiouaeioc'),
           '[^a-z]+') AS w
   WHERE length(w) >= 3;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_un_cambio(a text, b text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  la int := length(a); lb int := length(b); i int := 1; j int := 1; edits int := 0;
BEGIN
  IF a = b THEN RETURN true; END IF;
  IF abs(la - lb) > 1 THEN RETURN false; END IF;
  WHILE i <= la AND j <= lb LOOP
    IF substr(a, i, 1) = substr(b, j, 1) THEN
      i := i + 1; j := j + 1;
    ELSE
      edits := edits + 1;
      IF edits > 1 THEN RETURN false; END IF;
      IF la > lb THEN i := i + 1;
      ELSIF lb > la THEN j := j + 1;
      ELSE i := i + 1; j := j + 1;
      END IF;
    END IF;
  END LOOP;
  RETURN edits + (la - i + 1) + (lb - j + 1) <= 1;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_nombre_coincide(p_nombre_carnet text, p_nombre_beneficiario text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH c AS (SELECT cerebro_palabras_nombre(p_nombre_carnet) AS w),
       r AS (SELECT cerebro_palabras_nombre(p_nombre_beneficiario) AS w),
       m AS (SELECT count(*) AS n
               FROM r, unnest(r.w) AS rw
              WHERE EXISTS (SELECT 1 FROM c, unnest(c.w) AS cw WHERE cerebro_un_cambio(rw, cw)))
  SELECT CASE WHEN cardinality(c.w) = 0 OR cardinality(r.w) = 0 THEN false
              ELSE m.n >= least(2, cardinality(r.w)) END
    FROM c, r, m;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_palabras_nombre(text), public.cerebro_un_cambio(text, text),
                       public.cerebro_nombre_coincide(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_palabras_nombre(text), public.cerebro_un_cambio(text, text),
                          public.cerebro_nombre_coincide(text, text) TO service_role;
