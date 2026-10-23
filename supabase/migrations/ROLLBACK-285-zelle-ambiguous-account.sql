-- ROLLBACK 285: back to the 274 body of cerebro_guardar_zelle.
CREATE OR REPLACE FUNCTION public.cerebro_guardar_zelle(p_conv uuid, p_nombre text, p_cuenta text, p_exec text, p_op uuid DEFAULT NULL::uuid, p_tool text DEFAULT 'registrar_beneficiario_zelle'::text, p_posicion integer DEFAULT NULL::integer, p_agregar boolean DEFAULT false, p_monto numeric DEFAULT NULL::numeric)
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
