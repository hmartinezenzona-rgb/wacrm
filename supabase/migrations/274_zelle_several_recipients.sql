-- 274 (Zelle: several recipients on one operation). Part of the agent-tools work (odd/notes/db-tools-progress.md, gap 1 of
-- the S5b measurement, case C: "Maria Lopez" was marked 'reemplazado' by the second recipient "Juan Perez").
--   * cerebro_guardar_zelle gains p_posicion (slot to correct, 1..N+1), p_agregar (add another recipient) and p_monto (USD
--     for that recipient, optional). The signature grows from 6 to 9 arguments: the 6-argument function is dropped and the
--     new one keeps every default, so the tool's 4-argument call and cerebro_guardar_zelle_auto's 6-argument call work as before.
--   * Rules. One recipient and no parameter: the old behaviour (same account = correction; a different account replaces and
--     starts without holder), now with a hint to use p_agregar when it is another person. Several recipients and no
--     parameter: the SAME account corrects that recipient only; a different account writes NOTHING and the answer names
--     agregar / posicion. p_agregar adds (same account as an existing recipient = that recipient is patched, never
--     duplicated). p_posicion = k patches slot k (a new account starts without holder); k = N+1 appends; beyond is refused.
--   * Several recipients (or an amount) are written as ONE generation, block 'ZELLE VARIOS DESTINATARIOS', one line each;
--     cerebro_parsear_beneficiarios reads it (positions 1..N, amount USD). A single recipient without amount keeps the old
--     'BENEFICIARIO ZELLE' block, so every existing reader sees the same rows.
--   * The operation is the one the caller passes (p_op, the 250 several-operations targeting) or the old resolver's; other
--     operations are never touched. Names and accounts are stored exactly as passed (account normalised as before).
-- ACL: service_role only, as before. Rollback restores the 6-argument function and the previous parser.

DROP FUNCTION IF EXISTS public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text);

CREATE OR REPLACE FUNCTION public.cerebro_guardar_zelle(p_conv uuid, p_nombre text, p_cuenta text, p_exec text,
    p_op uuid DEFAULT NULL::uuid, p_tool text DEFAULT 'registrar_beneficiario_zelle'::text,
    p_posicion integer DEFAULT NULL::integer, p_agregar boolean DEFAULT false, p_monto numeric DEFAULT NULL::numeric)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_a text := cerebro_norm_cuenta_zelle(p_cuenta);
  v_n text := NULLIF(btrim(coalesce(p_nombre, '')), '');
  v_r record; v_tiene boolean;
  v_names text[] := ARRAY[]::text[]; v_accts text[] := ARRAY[]::text[]; v_amts numeric[] := ARRAY[]::numeric[];
  v_cnt int := 0; v_i int; v_k int; v_hit int := NULL;
  v_cn text; v_ca text; v_cm numeric;
  v_name text; v_acc text; v_amt numeric;
  v_legacy_replace boolean := false;
  v_block text; v_lineas text := ''; v_lista text := ''; v_falta text := ''; v_deal uuid; v_b record;
  v_cambio boolean;
BEGIN
  IF p_monto IS NOT NULL AND p_monto <= 0 THEN
    RETURN QUERY SELECT NULL::uuid, 'ERROR: el monto de ese destinatario tiene que ser mayor que 0. No se guardo nada.'::text; RETURN;
  END IF;
  IF v_a IS NULL AND v_n IS NULL AND p_monto IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, 'sin cambios: no llego ningun dato'::text; RETURN;
  END IF;
  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, p_tool, p_exec,
                                                        jsonb_build_array(p_nombre, p_cuenta), p_op);
  IF v_r.o_ambigua THEN
    RETURN QUERY SELECT NULL::uuid, 'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text;
    RETURN;
  END IF;

  -- The recipients in force on the operation, in slot order.
  IF v_r.o_op IS NOT NULL THEN
    FOR v_b IN SELECT b.name, b.zelle_account, b.amount FROM remittance_beneficiaries b
                WHERE b.operation_id = v_r.o_op AND b.status = 'vigente' AND b.beneficiary_type = 'zelle'
                ORDER BY b.position, b.block_index, b.created_at LOOP
      v_cnt := v_cnt + 1;
      v_names := v_names || v_b.name; v_accts := v_accts || v_b.zelle_account; v_amts := v_amts || v_b.amount;
    END LOOP;
  END IF;

  -- Which slot this call is about.
  IF v_a IS NOT NULL THEN
    FOR v_i IN 1 .. v_cnt LOOP
      IF lower(v_accts[v_i]) = lower(v_a) THEN v_hit := v_i; EXIT; END IF;
    END LOOP;
  END IF;
  IF p_agregar THEN
    v_k := coalesce(v_hit, v_cnt + 1);
  ELSIF p_posicion IS NOT NULL THEN
    IF p_posicion < 1 OR p_posicion > v_cnt + 1 THEN
      RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: la posicion ' || p_posicion || ' no existe. Hay ' || v_cnt
        || ' destinatario(s) Zelle: usa una posicion de 1 a ' || (v_cnt + 1) || ' (' || (v_cnt + 1) || ' es para sumar uno nuevo).')::text;
      RETURN;
    END IF;
    v_k := p_posicion;
  ELSIF v_cnt = 0 THEN
    v_k := 1;
  ELSIF v_hit IS NOT NULL THEN
    v_k := v_hit;
  ELSIF v_cnt = 1 THEN
    v_k := 1;
  ELSE
    FOR v_i IN 1 .. v_cnt LOOP
      v_lista := v_lista || CASE WHEN v_lista = '' THEN '' ELSE '; ' END
                 || v_i || ') ' || coalesce(v_names[v_i], '(falta nombre)') || ' / ' || coalesce(v_accts[v_i], '(falta cuenta)');
    END LOOP;
    RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: este envio ya tiene ' || v_cnt || ' destinatarios Zelle (' || v_lista
      || ') y esa cuenta no es ninguna de ellas. Si es OTRO destinatario llama con agregar=true; si corriges uno, indica su posicion (1 a '
      || v_cnt || '). Si no esta claro, preguntaselo al cliente.')::text;
    RETURN;
  END IF;

  v_cn := CASE WHEN v_k <= v_cnt THEN v_names[v_k] END;
  v_ca := CASE WHEN v_k <= v_cnt THEN v_accts[v_k] END;
  v_cm := CASE WHEN v_k <= v_cnt THEN v_amts[v_k] END;
  -- A different account starts without a holder (the name belongs to the account it came with).
  IF v_a IS NOT NULL AND v_ca IS NOT NULL AND lower(v_a) <> lower(v_ca) THEN
    v_acc := v_a; v_name := v_n; v_amt := p_monto;
    v_legacy_replace := NOT p_agregar AND p_posicion IS NULL AND v_cnt = 1;
  ELSE
    v_acc := coalesce(v_a, v_ca); v_name := coalesce(v_n, v_cn); v_amt := coalesce(p_monto, v_cm);
  END IF;

  v_cambio := v_k > v_cnt OR v_acc IS DISTINCT FROM v_ca OR v_name IS DISTINCT FROM v_cn OR v_amt IS DISTINCT FROM v_cm;
  IF v_k > v_cnt THEN
    v_names := v_names || v_name; v_accts := v_accts || v_acc; v_amts := v_amts || v_amt;
    v_cnt := v_cnt + 1;
  ELSE
    v_names[v_k] := v_name; v_accts[v_k] := v_acc; v_amts[v_k] := v_amt;
  END IF;

  FOR v_i IN 1 .. v_cnt LOOP
    v_falta := v_falta || concat_ws(' y ', CASE WHEN v_names[v_i] IS NULL THEN 'el nombre del titular' END,
                                          CASE WHEN v_accts[v_i] IS NULL THEN 'la cuenta (correo o celular de EEUU)' END)
               || CASE WHEN v_names[v_i] IS NULL OR v_accts[v_i] IS NULL
                       THEN CASE WHEN v_cnt > 1 THEN ' del destinatario ' || v_i ELSE '' END || '; ' ELSE '' END;
    v_lista := CASE WHEN v_i = 1 THEN '' ELSE v_lista END
               || CASE WHEN v_i = 1 THEN '' ELSE '; ' END || v_i || ') ' || coalesce(v_names[v_i], '(falta nombre)') || ' / '
               || coalesce(v_accts[v_i], '(falta cuenta)') || CASE WHEN v_amts[v_i] IS NOT NULL THEN ' / ' || trim_scale(v_amts[v_i])::text || ' USD' ELSE '' END;
  END LOOP;
  v_falta := rtrim(v_falta, '; ');

  IF NOT v_cambio THEN
    RETURN QUERY SELECT NULL::uuid, ('sin cambios: esos datos ya estaban guardados'
      || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta ELSE '' END)::text;
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = v_r.o_op) INTO v_tiene;
  IF v_cnt = 1 AND v_amts[1] IS NULL THEN
    v_block := CASE WHEN v_tiene THEN 'BENEFICIARIO ZELLE ACTUALIZADO - reemplaza al anterior' ELSE 'BENEFICIARIO ZELLE' END
               || E'\nNombre: ' || coalesce(v_names[1], '-') || E'\nCuenta Zelle: ' || coalesce(v_accts[1], '-');
  ELSE
    FOR v_i IN 1 .. v_cnt LOOP
      v_lineas := v_lineas || E'\n' || v_i || ') Nombre: ' || coalesce(replace(replace(v_names[v_i], E'\n', ' '), E'\r', ' '), '-')
                  || ' | Cuenta Zelle: ' || coalesce(replace(replace(v_accts[v_i], E'\n', ' '), E'\r', ' '), '-')
                  || ' | Recibe: ' || CASE WHEN v_amts[v_i] IS NOT NULL THEN trim_scale(v_amts[v_i])::text || ' USD' ELSE '-' END;
    END LOOP;
    v_block := 'ZELLE VARIOS DESTINATARIOS' || v_lineas;
  END IF;
  v_deal := cerebro_escribir_bloque_beneficiario(p_conv, v_r.o_op, v_block);

  RETURN QUERY SELECT v_deal, (
    CASE WHEN v_cnt = 1 AND v_amts[1] IS NULL THEN 'guardado: titular ' || coalesce(v_name, '(falta)') || ', cuenta ' || coalesce(v_acc, '(falta)')
         ELSE 'guardado (destinatario ' || v_k || ' de ' || v_cnt || '): titular ' || coalesce(v_name, '(falta)') || ', cuenta ' || coalesce(v_acc, '(falta)')
              || CASE WHEN v_amt IS NOT NULL THEN ', monto ' || trim_scale(v_amt)::text || ' USD' ELSE '' END END
    || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta || '. Pideselo al cliente.' ELSE '. Completo.' END
    || CASE WHEN v_cnt > 1 THEN ' Destinatarios Zelle ahora: ' || v_lista || '.' ELSE '' END
    || CASE WHEN v_legacy_replace THEN ' (Reemplazo al destinatario anterior; si es OTRA persona, no una correccion, vuelve a llamar con agregar=true.)' ELSE '' END)::text;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text, integer, boolean, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text, integer, boolean, numeric) TO service_role;

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

    ELSIF v_b ~ '^ZELLE VARIOS DESTINATARIOS' THEN
      -- (274) Several Zelle recipients of one operation, one line each: "<n>) Nombre: <x> | Cuenta Zelle: <y> | Recibe: <usd> USD".
      -- Any field may be "-"; the line number is the position; an amount is USD.
      FOR v_fila IN
        SELECT regexp_matches(v_b, '^([0-9]+)\) Nombre: (.*) \| Cuenta Zelle: (.*) \| Recibe: (?:([0-9]+(?:\.[0-9]+)?) USD|-)$', 'gn')
      LOOP
        block_index := v_i; tipo := 'zelle';
        nombre := NULLIF(v_fila[2], '-'); tarjeta := NULL; celular := NULL;
        cuenta_zelle := NULLIF(v_fila[3], '-');
        monto := v_fila[4]::numeric; moneda := CASE WHEN v_fila[4] IS NULL THEN NULL ELSE 'USD' END;
        posicion := v_fila[1]::integer;
        IF cuenta_zelle IS NOT NULL OR coalesce(nombre, '') <> '' THEN RETURN NEXT; END IF;
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
