-- Rollback of 274: restores the 6-argument cerebro_guardar_zelle and the previous cerebro_parsear_beneficiarios.
-- It FAILS (on purpose) if a 'ZELLE VARIOS DESTINATARIOS' generation is in force; retire it first.
DO $$ BEGIN IF EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.status = 'vigente' AND b.beneficiary_type = 'zelle'
   AND (SELECT count(*) FROM remittance_beneficiaries x WHERE x.operation_id = b.operation_id AND x.status = 'vigente' AND x.beneficiary_type = 'zelle') > 1)
 THEN RAISE EXCEPTION 'rollback 274: an operation has several vigente Zelle recipients'; END IF; END $$;
DROP FUNCTION IF EXISTS public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text, integer, boolean, numeric);

CREATE OR REPLACE FUNCTION public.cerebro_guardar_zelle(p_conv uuid, p_nombre text, p_cuenta text, p_exec text, p_op uuid DEFAULT NULL::uuid, p_tool text DEFAULT 'registrar_beneficiario_zelle'::text)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_a text := cerebro_norm_cuenta_zelle(p_cuenta);
  v_n text := NULLIF(btrim(coalesce(p_nombre, '')), '');
  v_r record; v_cur record; v_tiene boolean;
  v_acc text; v_name text; v_deal uuid; v_falta text;
BEGIN
  IF v_a IS NULL AND v_n IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, 'sin cambios: no llego ningun dato'::text; RETURN;
  END IF;
  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, p_tool, p_exec,
                                                        jsonb_build_array(p_nombre, p_cuenta), p_op);
  IF v_r.o_ambigua THEN
    RETURN QUERY SELECT NULL::uuid, 'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text;
    RETURN;
  END IF;

  SELECT b.zelle_account, b.name INTO v_cur
    FROM remittance_beneficiaries b
   WHERE b.operation_id = v_r.o_op AND b.status = 'vigente' AND b.beneficiary_type = 'zelle'
   ORDER BY b.block_index DESC LIMIT 1;

  -- A different account starts without a holder (the name belongs to the account it came with).
  IF v_a IS NOT NULL AND v_cur.zelle_account IS NOT NULL AND lower(v_a) <> lower(v_cur.zelle_account) THEN
    v_acc := v_a; v_name := v_n;
  ELSE
    v_acc := coalesce(v_a, v_cur.zelle_account);
    v_name := coalesce(v_n, v_cur.name);
  END IF;
  v_falta := concat_ws(' y ', CASE WHEN v_name IS NULL THEN 'el nombre del titular' END, CASE WHEN v_acc IS NULL THEN 'la cuenta (correo o celular de EEUU)' END);

  IF v_acc IS NOT DISTINCT FROM v_cur.zelle_account AND v_name IS NOT DISTINCT FROM v_cur.name THEN
    RETURN QUERY SELECT NULL::uuid, ('sin cambios: esos datos ya estaban guardados'
      || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta ELSE '' END)::text;
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = v_r.o_op) INTO v_tiene;
  v_deal := cerebro_escribir_bloque_beneficiario(p_conv, v_r.o_op,
      CASE WHEN v_tiene THEN 'BENEFICIARIO ZELLE ACTUALIZADO - reemplaza al anterior' ELSE 'BENEFICIARIO ZELLE' END
      || E'\nNombre: ' || coalesce(v_name, '-') || E'\nCuenta Zelle: ' || coalesce(v_acc, '-'));
  RETURN QUERY SELECT v_deal, ('guardado: titular ' || coalesce(v_name, '(falta)') || ', cuenta ' || coalesce(v_acc, '(falta)')
    || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta || '. Pideselo al cliente.' ELSE '. Completo.' END)::text;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text) TO service_role;

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
      -- (179) Any field may be "-" (not given yet); "- USD Clasica" keeps the rail without amount.
      FOR v_fila IN
        SELECT regexp_matches(v_b, '([0-9]+)\) Tarjeta: ([0-9]+|-) \| Celular: ([0-9]+|-) \| Recibe: (?:([0-9]+|-) (CUP|USD)(?: (Clasica|Tropical))?|-)', 'g')
      LOOP
        CONTINUE WHEN v_fila[5] = 'USD' AND v_fila[6] IS NULL;
        CONTINUE WHEN v_fila[2] = '-' AND v_fila[3] = '-' AND coalesce(v_fila[4], '-') = '-';
        block_index := v_i;
        tipo := CASE WHEN v_fila[5] = 'USD' THEN lower(v_fila[6]) ELSE 'multiple_distribution' END;
        nombre := NULL;
        tarjeta := NULLIF(v_fila[2], '-'); celular := NULLIF(v_fila[3], '-'); cuenta_zelle := NULL;
        monto := NULLIF(v_fila[4], '-')::numeric;
        moneda := CASE WHEN NULLIF(v_fila[4], '-') IS NULL THEN NULL ELSE v_fila[5] END;
        posicion := v_fila[1]::integer;
        RETURN NEXT;
      END LOOP;

    ELSIF v_b ~ '^BENEFICIARIO ZELLE' THEN
      block_index := v_i; tipo := 'zelle';
      nombre := NULLIF(substring(v_b from 'Nombre: ([^\n]*)'), '-');
      tarjeta := NULL; celular := NULL;
      cuenta_zelle := NULLIF(substring(v_b from 'Cuenta Zelle: ([^\n]*)'), '-');
      monto := NULL; moneda := NULL; posicion := 1;
      -- (179) A holder without an account is a partial row too.
      IF cuenta_zelle IS NOT NULL OR coalesce(nombre, '') <> '' THEN RETURN NEXT; END IF;

    ELSIF v_b ~ '^BENEFICIARIO' THEN
      block_index := v_i; tipo := 'cuban_card';
      nombre := substring(v_b from '^BENEFICIARIO[^\n(]*\(([^)]*)\)');
      tarjeta := substring(v_b from 'Tarjeta: ([0-9]+)');
      celular := substring(v_b from 'Celular: ([0-9]+)');
      cuenta_zelle := NULL; monto := NULL; moneda := NULL; posicion := 1;
      IF nombre = 'auto' THEN nombre := NULL; END IF;
      -- (179) A phone without a card is a partial row too, when it is a Cuban mobile (an old
      -- block holding a US number as "Celular" must not become a beneficiary).
      IF tarjeta IS NOT NULL OR celular ~ '^(5[0-9]{7}|63[0-9]{6})$' THEN RETURN NEXT; END IF;
    END IF;
  END LOOP;
END $function$;
