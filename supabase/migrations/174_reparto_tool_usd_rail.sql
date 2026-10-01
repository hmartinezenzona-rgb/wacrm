-- =====================================================================
-- 174 — the LLM reparto tool records Clasica/Tropical shares in USD
--
-- Real case: Kenia 5927478061 (2026-09-29): 150 USD = 100 Zelle + 30 + 20 USD
-- to two Clasica cards. The Cerebro tool `registrar_reparto_multiple` (the
-- path the LLM takes when the deterministic reparto detector cannot read the
-- chat) writes every share as "Recibe: <n> CUP", so the panel showed the two
-- Clasica cards as a CUP reparto of 30 and 20 CUP. Same class of bug as
-- a29ef5e8 (169), on the other reparto path.
--
-- The tool now passes each share WITH its currency and rail ("45000 CUP",
-- "30 USD clasica") in the same 11 arguments, and writes
-- "Recibe: 30 USD Clasica" in the block. This migration:
--   1. cerebro_parsear_beneficiarios reads "Recibe: <n> USD Clasica|Tropical"
--      as a clasica/tropical row in USD; "Recibe: <n> CUP" (every block already
--      stored) reads exactly as before.
--   2. cerebro_detectar_destino (157) also recognises the plurals "clasicas"
--      and "tropicales": Kenia wrote "a unas tarjetas clasicas" and the rail
--      was never noted.
--
-- For the eliminate-deals work: 163's cerebro_registrar_reparto_multiple must
-- accept the same "<n> USD clasica|tropical" values (arity unchanged).
--
-- Guarded by supabase/staging/assertions/reparto-tool-usd-rail.sql
-- ROLLBACK: ROLLBACK-174-reparto-tool-usd-rail.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_parsear_beneficiarios(p_notes text)
 RETURNS TABLE(block_index integer, tipo text, nombre text, tarjeta text, celular text, cuenta_zelle text, monto numeric, moneda text, posicion integer)
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_bloques text[];
  v_b text;
  v_i integer := 0;
  v_fila text[];
BEGIN
  v_bloques := regexp_split_to_array(coalesce(p_notes,''), E'\n---\n');

  FOREACH v_b IN ARRAY v_bloques LOOP
    v_i := v_i + 1;

    IF v_b ~ '^REPARTO' THEN
      -- (174) A share is "<n> CUP" (a CUP card, as always) or "<n> USD Clasica|Tropical".
      FOR v_fila IN
        SELECT regexp_matches(v_b, '([0-9]+)\) Tarjeta: ([0-9]+) \| Celular: ([0-9]+) \| Recibe: ([0-9]+) (CUP|USD)(?: (Clasica|Tropical))?', 'g')
      LOOP
        CONTINUE WHEN v_fila[5] = 'USD' AND v_fila[6] IS NULL;
        block_index := v_i;
        tipo := CASE WHEN v_fila[5] = 'CUP' THEN 'multiple_distribution' ELSE lower(v_fila[6]) END;
        nombre := NULL;
        tarjeta := v_fila[2]; celular := v_fila[3]; cuenta_zelle := NULL;
        monto := v_fila[4]::numeric; moneda := v_fila[5]; posicion := v_fila[1]::integer;
        RETURN NEXT;
      END LOOP;

    ELSIF v_b ~ '^BENEFICIARIO ZELLE' THEN
      block_index := v_i; tipo := 'zelle';
      nombre := substring(v_b from 'Nombre: ([^\n]*)');
      tarjeta := NULL; celular := NULL;
      cuenta_zelle := substring(v_b from 'Cuenta Zelle: ([^\n]*)');
      monto := NULL; moneda := NULL; posicion := 1;
      IF cuenta_zelle IS NOT NULL THEN RETURN NEXT; END IF;

    ELSIF v_b ~ '^BENEFICIARIO' THEN
      block_index := v_i; tipo := 'cuban_card';
      nombre := substring(v_b from '^BENEFICIARIO[^\n(]*\(([^)]*)\)');
      tarjeta := substring(v_b from 'Tarjeta: ([0-9]+)');
      celular := substring(v_b from 'Celular: ([0-9]+)');
      cuenta_zelle := NULL; monto := NULL; moneda := NULL; posicion := 1;
      IF nombre = 'auto' THEN nombre := NULL; END IF;
      IF tarjeta IS NOT NULL THEN RETURN NEXT; END IF;
    END IF;
  END LOOP;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_detectar_destino(p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_txt      text := coalesce(p_texto, '');
  v_clasica  boolean;
  v_tropical boolean;
  v_cup      boolean;
BEGIN
  -- (174) Plurals too: "a unas tarjetas clasicas", "a las tropicales".
  v_clasica  := v_txt ~* '(^|[^[:alnum:]])cl[aáAÁ]sicas?([^[:alnum:]]|$)';
  v_tropical := v_txt ~* '(^|[^[:alnum:]])tropical(es)?([^[:alnum:]]|$)';
  v_cup      := v_txt ~* '(^|[^[:alnum:]])cup([^[:alnum:]]|$)'
             OR v_txt ~* '(^|[^[:alnum:]])pesos[[:space:]]+cubanos([^[:alnum:]]|$)';

  IF v_clasica AND NOT v_tropical THEN
    RETURN 'clasica';
  ELSIF v_tropical AND NOT v_clasica THEN
    RETURN 'tropical';
  ELSIF v_cup AND NOT v_clasica AND NOT v_tropical THEN
    RETURN 'cuban_card';
  END IF;

  -- Both rails named, or nothing this function recognises.
  RETURN NULL;
END $function$;
