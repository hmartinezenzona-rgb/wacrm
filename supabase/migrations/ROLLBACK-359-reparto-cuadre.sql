-- ROLLBACK for 359: restores the 358 body of cerebro_guardar_reparto and removes cerebro_reparto_cuadre and cerebro_reparto_sumas.

CREATE OR REPLACE FUNCTION public.cerebro_guardar_reparto(p_conv uuid, p_t1 text, p_c1 text, p_m1 text, p_t2 text, p_c2 text, p_m2 text, p_t3 text, p_c3 text, p_m3 text, p_exec text, p_op uuid DEFAULT NULL::uuid, p_tool text DEFAULT 'registrar_reparto_multiple'::text)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t text[] := ARRAY[cerebro_norm_tarjeta(p_t1), cerebro_norm_tarjeta(p_t2), cerebro_norm_tarjeta(p_t3)];
  v_c text[] := ARRAY[cerebro_norm_celular_cu(p_c1), cerebro_norm_celular_cu(p_c2), cerebro_norm_celular_cu(p_c3)];
  v_m text[] := ARRAY[NULLIF(btrim(coalesce(p_m1, '')), ''), NULLIF(btrim(coalesce(p_m2, '')), ''), NULLIF(btrim(coalesce(p_m3, '')), '')];
  v_pend text;
  v_r record; v_tiene boolean; v_deal uuid;
  v_ct text[] := ARRAY[NULL, NULL, NULL]; v_cc text[] := ARRAY[NULL, NULL, NULL];
  v_ca text[] := ARRAY[NULL, NULL, NULL];   -- saved share, as written in the block ("15000 CUP", "30 USD Clasica", "- USD Clasica")
  v_nt text[]; v_nc text[]; v_na text[];
  v_k int; v_num text; v_riel text; v_err text := '';
  v_lineas text := ''; v_resumen text := ''; v_falta text := ''; v_cambio boolean := false;
  v_b record;
  -- (358) guard against the verified deposit
  v_dsp record; v_nuevo boolean; v_slots int := 0; v_con int := 0; v_ncup int := 0; v_nusd int := 0;
  v_amt numeric; v_sum_gyd numeric := 0; v_sum_cup numeric := 0; v_sum_usd numeric := 0; v_tol numeric; v_rem numeric;
  v_suman text; v_aviso text := '';
BEGIN
  FOR v_k IN 1..3 LOOP
    IF v_t[v_k] = '!' THEN v_err := v_err || 'La tarjeta ' || v_k || ' tiene que tener 16 digitos. '; END IF;
    IF v_c[v_k] = '!' THEN v_err := v_err || 'El celular ' || v_k || ' no es un celular cubano (8 digitos, empieza por 5 o 63). '; END IF;
  END LOOP;
  -- Shares: "45000 CUP" (CUP card), "30 USD clasica|tropical"; a bare USD amount takes the rail
  -- the customer named (cerebro_destino_pendiente) or is refused; a bare number is CUP. (174)
  SELECT CASE dp.tipo WHEN 'clasica' THEN 'Clasica' WHEN 'tropical' THEN 'Tropical' END INTO v_pend
    FROM cerebro_destino_pendiente dp WHERE dp.conversation_id = p_conv AND dp.actualizado > now() - interval '24 hours';
  v_na := ARRAY[NULL, NULL, NULL];
  FOR v_k IN 1..3 LOOP
    CONTINUE WHEN v_m[v_k] IS NULL;
    v_num := NULLIF(regexp_replace(v_m[v_k], '[^0-9]', '', 'g'), '');
    v_riel := CASE WHEN v_m[v_k] ~* 'tropical' THEN 'Tropical' WHEN v_m[v_k] ~* 'cl[aá]sica' THEN 'Clasica'
                   WHEN v_m[v_k] ~* '(usd|d[oó]lar)' THEN coalesce(v_pend, '?') END;
    IF v_riel = '?' THEN
      v_err := v_err || 'El monto ' || v_k || ' esta en dolares pero no dice si es tarjeta Clasica o Tropical: preguntaselo al cliente. ';
    ELSIF v_riel IS NOT NULL THEN
      v_na[v_k] := coalesce(v_num, '-') || ' USD ' || v_riel;
    ELSIF v_num IS NOT NULL THEN
      v_na[v_k] := v_num || ' CUP';
    END IF;
  END LOOP;
  IF v_err <> '' THEN
    RETURN QUERY SELECT NULL::uuid, ('ERROR: no se guardo nada. ' || v_err || 'Pide el dato que falta con naturalidad.')::text;
    RETURN;
  END IF;
  IF (SELECT bool_and(x IS NULL) FROM unnest(v_t || v_c || v_na) x) THEN
    RETURN QUERY SELECT NULL::uuid, 'sin cambios: no llego ningun dato'::text; RETURN;
  END IF;

  -- (184) cerebro_guardar_beneficiario patches a slot of the reparto of the operation it resolved.
  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, p_tool, p_exec,
                                                        jsonb_build_array(p_t1, p_c1, p_m1, p_t2, p_c2, p_m2, p_t3, p_c3, p_m3), p_op);
  IF v_r.o_ambigua THEN
    RETURN QUERY SELECT NULL::uuid, 'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text;
    RETURN;
  END IF;

  -- The reparto saved now, slot by slot.
  FOR v_b IN
    SELECT b.position, b.card_number, b.phone, b.amount, b.currency, b.beneficiary_type
      FROM remittance_beneficiaries b
     WHERE b.operation_id = v_r.o_op AND b.status = 'vigente'
       AND b.beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical') AND b.position BETWEEN 1 AND 3
  LOOP
    v_ct[v_b.position] := v_b.card_number; v_cc[v_b.position] := v_b.phone;
    v_ca[v_b.position] := CASE WHEN v_b.beneficiary_type IN ('clasica', 'tropical')
                               THEN coalesce(trim(to_char(v_b.amount, 'FM999999999')), '-') || ' USD ' || initcap(v_b.beneficiary_type)
                               WHEN v_b.amount IS NOT NULL THEN trim(to_char(v_b.amount, 'FM999999999')) || ' CUP' END;
  END LOOP;

  -- (358) Is this call setting at least one amount? (decided before the merge with the saved slots)
  v_nuevo := EXISTS (SELECT 1 FROM unnest(v_na) x WHERE x ~ '^[0-9]');

  -- D1 per slot: a different card in a slot starts without phone and share; otherwise patch.
  v_nt := v_ct; v_nc := v_cc;
  FOR v_k IN 1..3 LOOP
    IF v_t[v_k] IS NOT NULL AND v_ct[v_k] IS NOT NULL AND v_t[v_k] <> v_ct[v_k] THEN
      v_nt[v_k] := v_t[v_k]; v_nc[v_k] := v_c[v_k]; v_na[v_k] := v_na[v_k];
    ELSE
      v_nt[v_k] := coalesce(v_t[v_k], v_ct[v_k]); v_nc[v_k] := coalesce(v_c[v_k], v_cc[v_k]);
      v_na[v_k] := coalesce(v_na[v_k], v_ca[v_k]);
    END IF;
    IF v_nt[v_k] IS DISTINCT FROM v_ct[v_k] OR v_nc[v_k] IS DISTINCT FROM v_cc[v_k] OR v_na[v_k] IS DISTINCT FROM v_ca[v_k] THEN
      v_cambio := true;
    END IF;
    CONTINUE WHEN v_nt[v_k] IS NULL AND v_nc[v_k] IS NULL AND v_na[v_k] IS NULL;
    v_lineas := v_lineas || E'\n' || v_k || ') Tarjeta: ' || coalesce(v_nt[v_k], '-') || ' | Celular: ' || coalesce(v_nc[v_k], '-')
                || ' | Recibe: ' || coalesce(v_na[v_k], '-');
    v_resumen := v_resumen || CASE WHEN v_resumen = '' THEN '' ELSE ' | ' END
                 || v_k || ') tarjeta ' || coalesce(v_nt[v_k], '(falta)') || ', celular ' || coalesce(v_nc[v_k], '(falta)')
                 || ', recibe ' || coalesce(replace(v_na[v_k], '- ', '(falta monto) '), '(falta)');
    v_falta := v_falta || concat_ws(', ',
                 CASE WHEN v_nt[v_k] IS NULL THEN 'la tarjeta ' || v_k END,
                 CASE WHEN v_nc[v_k] IS NULL THEN 'el celular de la tarjeta ' || v_k END,
                 CASE WHEN v_na[v_k] IS NULL OR v_na[v_k] LIKE '- %' THEN 'cuanto recibe la tarjeta ' || v_k END)
               || CASE WHEN v_nt[v_k] IS NULL OR v_nc[v_k] IS NULL OR v_na[v_k] IS NULL OR v_na[v_k] LIKE '- %' THEN '; ' ELSE '' END;
  END LOOP;
  v_falta := rtrim(v_falta, '; ');

  -- (358) The merged amounts (saved + new) cannot contradict a VERIFIED deposit. Compared in GYD with the rate the bot quotes
  -- with (CUP / gyd rate, USD * usd rate); tolerance: 1 CUP per CUP card and 1 USD per USD card (per-card rounding).
  -- Over the deposit: nothing is written. Some cards without amount: saved, the reply says what is left. Every card with
  -- amount but under the deposit: saved, but never "Completo" (the leftover is a FALTA). Unverified deposit or a call
  -- without amounts (card / phone patches): exactly the previous behavior.
  IF v_nuevo AND v_r.o_op IS NOT NULL THEN
    SELECT * INTO v_dsp FROM cerebro_reparto_disponible(v_r.o_op);
    IF v_dsp.base_gyd IS NOT NULL AND coalesce(v_dsp.tasa_cup, 0) > 0 AND coalesce(v_dsp.tasa_usd, 0) > 0 THEN
      FOR v_k IN 1..3 LOOP
        CONTINUE WHEN v_nt[v_k] IS NULL AND v_nc[v_k] IS NULL AND v_na[v_k] IS NULL;
        v_slots := v_slots + 1;
        CONTINUE WHEN v_na[v_k] IS NULL OR v_na[v_k] !~ '^[0-9]';
        v_amt := (regexp_match(v_na[v_k], '^[0-9]+'))[1]::numeric;
        v_con := v_con + 1;
        IF v_na[v_k] LIKE '% CUP' THEN
          v_ncup := v_ncup + 1; v_sum_cup := v_sum_cup + v_amt; v_sum_gyd := v_sum_gyd + v_amt / v_dsp.tasa_cup;
        ELSE
          v_nusd := v_nusd + 1; v_sum_usd := v_sum_usd + v_amt; v_sum_gyd := v_sum_gyd + v_amt * v_dsp.tasa_usd;
        END IF;
      END LOOP;
      v_tol := v_ncup / v_dsp.tasa_cup + v_nusd * v_dsp.tasa_usd;
      v_rem := v_dsp.base_gyd - v_sum_gyd;
      v_suman := concat_ws(' + ', CASE WHEN v_ncup > 0 THEN trim_scale(v_sum_cup)::text || ' CUP' END,
                                  CASE WHEN v_nusd > 0 THEN trim_scale(v_sum_usd)::text || ' USD' END)
                 || CASE WHEN v_nusd > 0 THEN ', que equivalen a ' || trim_scale(round(v_sum_gyd))::text || ' GYD' ELSE '' END;
      IF v_sum_gyd > v_dsp.base_gyd + v_tol THEN
        RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: el deposito verificado de este envio es ' || trim_scale(v_dsp.base_gyd)::text
          || ' GYD = ' || trim_scale(v_dsp.total_cup)::text || ' CUP (o ' || trim_scale(v_dsp.total_usd)::text
          || ' USD en tarjeta Clasica/Tropical) y los montos de las tarjetas suman ' || v_suman
          || '. Eso es mas de lo que deposito el cliente: preguntale como quiere repartir ese total entre las tarjetas. No se cambio nada.')::text;
        RETURN;
      ELSIF v_con < v_slots THEN
        v_aviso := CASE WHEN v_rem > v_tol
          THEN ' Del deposito verificado (' || trim_scale(v_dsp.base_gyd)::text || ' GYD = ' || trim_scale(v_dsp.total_cup)::text
               || ' CUP) ya asignaste ' || v_suman || ': quedan ' || trim_scale(round(v_rem * v_dsp.tasa_cup))::text
               || ' CUP para las demas tarjetas (o unos ' || trim_scale(floor(v_rem / v_dsp.tasa_usd))::text || ' USD si alguna es Clasica/Tropical).'
          ELSE ' Los montos que ya asignaste (' || v_suman || ') cubren todo el deposito verificado (' || trim_scale(v_dsp.base_gyd)::text
               || ' GYD): no queda nada para las tarjetas sin monto; preguntale al cliente como ajusta el reparto.' END;
      ELSIF v_con > 0 AND v_rem > v_tol THEN
        v_falta := concat_ws('; ', NULLIF(v_falta, ''), 'sobran ' || trim_scale(round(v_rem * v_dsp.tasa_cup))::text
          || ' CUP del deposito verificado (' || trim_scale(v_dsp.base_gyd)::text || ' GYD = ' || trim_scale(v_dsp.total_cup)::text
          || ' CUP): pide al cliente que reparta todo el deposito o que diga que hacer con ese monto');
      END IF;
    END IF;
  END IF;

  IF NOT v_cambio THEN
    RETURN QUERY SELECT NULL::uuid, ('sin cambios: ese reparto ya estaba guardado'
      || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta ELSE '' END || v_aviso)::text;
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = v_r.o_op) INTO v_tiene;
  v_deal := cerebro_escribir_bloque_beneficiario(p_conv, v_r.o_op,
      CASE WHEN v_tiene THEN 'REPARTO ACTUALIZADO ENTRE VARIOS BENEFICIARIOS - reemplaza lo anterior'
           ELSE 'REPARTO ENTRE VARIOS BENEFICIARIOS' END || v_lineas);
  RETURN QUERY SELECT v_deal, ('reparto guardado: ' || v_resumen
    || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta || '. Pideselo al cliente, una pregunta por mensaje.' ELSE '. Completo.' END
    || v_aviso)::text;
END $function$;

DROP FUNCTION IF EXISTS public.cerebro_reparto_cuadre(uuid);
DROP FUNCTION IF EXISTS public.cerebro_reparto_sumas(text[], integer, numeric, numeric, numeric);
