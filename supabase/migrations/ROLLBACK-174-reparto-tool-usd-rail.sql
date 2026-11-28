-- ROLLBACK for 174: restores the CUP-only reparto parser and the singular-only rail detector (157).

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
      FOR v_fila IN
        SELECT regexp_matches(v_b, '([0-9]+)\) Tarjeta: ([0-9]+) \| Celular: ([0-9]+) \| Recibe: ([0-9]+) CUP', 'g')
      LOOP
        block_index := v_i; tipo := 'multiple_distribution'; nombre := NULL;
        tarjeta := v_fila[2]; celular := v_fila[3]; cuenta_zelle := NULL;
        monto := v_fila[4]::numeric; moneda := 'CUP'; posicion := v_fila[1]::integer;
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
  v_clasica  := v_txt ~* '(^|[^[:alnum:]])cl[aáAÁ]sica([^[:alnum:]]|$)';
  v_tropical := v_txt ~* '(^|[^[:alnum:]])tropical([^[:alnum:]]|$)';
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
