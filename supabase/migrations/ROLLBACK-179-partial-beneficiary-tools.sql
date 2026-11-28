-- ROLLBACK 179: restore 174's cerebro_parsear_beneficiarios and drop the 179 functions.
-- Run only after the n8n tools no longer call cerebro_guardar_* (restore their pre-179 SQL first).

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

DROP FUNCTION IF EXISTS public.cerebro_guardar_reparto(uuid, text, text, text, text, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.cerebro_guardar_zelle(uuid, text, text, text);
DROP FUNCTION IF EXISTS public.cerebro_guardar_beneficiario(uuid, text, text, text, text);
DROP FUNCTION IF EXISTS public.cerebro_resolver_para_guardar(uuid, text, text, jsonb);
DROP FUNCTION IF EXISTS public.cerebro_escribir_bloque_beneficiario(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.cerebro_norm_cuenta_zelle(text);
DROP FUNCTION IF EXISTS public.cerebro_norm_celular_cu(text);
DROP FUNCTION IF EXISTS public.cerebro_norm_tarjeta(text);
