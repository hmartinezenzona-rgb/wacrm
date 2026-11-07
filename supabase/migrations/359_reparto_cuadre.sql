-- 359 -- The open reparto versus the verified deposit, for the conversation context (and one arithmetic for both).
--   * cerebro_reparto_sumas(slots, n, base, rate cup, rate usd): the single comparison used by the tool and the context:
--     sums per rail, tolerance (1 CUP per CUP card, 1 USD per USD card, in GYD), remainder and estado
--     (excede | faltan_montos | sobra | cuadra, in that precedence). IMMUTABLE, no table access.
--   * cerebro_reparto_cuadre(conversation): jsonb for the open operation that has a reparto (2 or 3 vigente slots of type
--     multiple_distribution / clasica / tropical) when its deposit is verified (cerebro_reparto_disponible); NULL otherwise.
--     Read by the Contexto conversacion node as ctx.reparto_cuadre. diferencia_cup is signed: positive = left over, negative = excess.
--   * cerebro_guardar_reparto is redefined from the 358 body only to call cerebro_reparto_sumas instead of its inline loop
--     (same behavior, same messages; the 358 assertion stays green). Rollback: ROLLBACK-359-reparto-cuadre.sql.

CREATE OR REPLACE FUNCTION public.cerebro_reparto_sumas(p_na text[], p_slots integer, p_base numeric, p_tasa_cup numeric, p_tasa_usd numeric)
 RETURNS TABLE(con integer, ncup integer, nusd integer, sum_cup numeric, sum_usd numeric, sum_gyd numeric, tol numeric, rem numeric, estado text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  WITH a AS (
    SELECT (regexp_match(x, '^[0-9]+'))[1]::numeric AS amt, x LIKE '% CUP' AS es_cup
      FROM unnest(p_na) AS t(x) WHERE x ~ '^[0-9]'
  ),
  s AS (
    SELECT count(*)::integer AS con,
           count(*) FILTER (WHERE es_cup)::integer AS ncup,
           count(*) FILTER (WHERE NOT es_cup)::integer AS nusd,
           coalesce(sum(amt) FILTER (WHERE es_cup), 0) AS sum_cup,
           coalesce(sum(amt) FILTER (WHERE NOT es_cup), 0) AS sum_usd
      FROM a
  ),
  t AS (
    SELECT s.*, s.sum_cup / p_tasa_cup + s.sum_usd * p_tasa_usd AS sum_gyd,
           s.ncup / p_tasa_cup + s.nusd * p_tasa_usd AS tol
      FROM s
  )
  SELECT t.con, t.ncup, t.nusd, t.sum_cup, t.sum_usd, t.sum_gyd, t.tol, p_base - t.sum_gyd,
         CASE WHEN t.sum_gyd > p_base + t.tol THEN 'excede'
              WHEN t.con < p_slots THEN 'faltan_montos'
              WHEN t.con > 0 AND p_base - t.sum_gyd > t.tol THEN 'sobra'
              ELSE 'cuadra' END
    FROM t;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_reparto_sumas(text[], integer, numeric, numeric, numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_reparto_sumas(text[], integer, numeric, numeric, numeric) TO service_role;

CREATE OR REPLACE FUNCTION public.cerebro_reparto_cuadre(p_conv uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op uuid; v_d record; v_s record; v_b record;
  v_na text[] := ARRAY[NULL, NULL, NULL];
  v_asig jsonb := '[]'::jsonb; v_n integer;
BEGIN
  -- The most recent open operation with a reparto (2 or 3 vigente slots), the same slot filter cerebro_guardar_reparto uses.
  SELECT o.id INTO v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
     AND (SELECT count(DISTINCT b.position) FROM remittance_beneficiaries b
           WHERE b.operation_id = o.id AND b.status = 'vigente'
             AND b.beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical') AND b.position BETWEEN 1 AND 3) >= 2
   ORDER BY o.created_at DESC, o.id
   LIMIT 1;
  IF v_op IS NULL THEN RETURN NULL; END IF;

  SELECT * INTO v_d FROM cerebro_reparto_disponible(v_op);
  IF v_d.base_gyd IS NULL OR coalesce(v_d.tasa_cup, 0) <= 0 OR coalesce(v_d.tasa_usd, 0) <= 0 THEN RETURN NULL; END IF;

  v_n := 0;
  FOR v_b IN
    SELECT b.position, b.amount, b.beneficiary_type
      FROM remittance_beneficiaries b
     WHERE b.operation_id = v_op AND b.status = 'vigente'
       AND b.beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical') AND b.position BETWEEN 1 AND 3
     ORDER BY b.position, b.created_at
  LOOP
    -- the slot text is written exactly as cerebro_guardar_reparto reads a saved share
    v_na[v_b.position] := CASE WHEN v_b.beneficiary_type IN ('clasica', 'tropical')
                               THEN coalesce(trim(to_char(v_b.amount, 'FM999999999')), '-') || ' USD ' || initcap(v_b.beneficiary_type)
                               WHEN v_b.amount IS NOT NULL THEN trim(to_char(v_b.amount, 'FM999999999')) || ' CUP' END;
    v_asig := v_asig || jsonb_build_array(jsonb_build_object(
                'posicion', v_b.position, 'monto', v_b.amount,
                'moneda', CASE WHEN v_b.beneficiary_type IN ('clasica', 'tropical') THEN 'USD' ELSE 'CUP' END));
  END LOOP;
  v_n := jsonb_array_length(v_asig);

  SELECT * INTO v_s FROM cerebro_reparto_sumas(v_na, v_n, v_d.base_gyd, v_d.tasa_cup, v_d.tasa_usd);

  RETURN jsonb_build_object(
    'op_id', v_op,
    'base_gyd', trim_scale(v_d.base_gyd),
    'total_cup', v_d.total_cup,
    'total_usd', v_d.total_usd,
    'tarjetas', v_n,
    'suma_cup_equiv', round(v_s.sum_gyd * v_d.tasa_cup),
    'asignado', v_asig,
    'estado', v_s.estado,
    'diferencia_cup', round(v_s.rem * v_d.tasa_cup),
    'por_tarjeta_igual_cup', floor(v_d.total_cup / v_n));
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_reparto_cuadre(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_reparto_cuadre(uuid) TO service_role;

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
  v_suman text; v_aviso text := ''; v_s record;
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
        IF NOT (v_nt[v_k] IS NULL AND v_nc[v_k] IS NULL AND v_na[v_k] IS NULL) THEN v_slots := v_slots + 1; END IF;
      END LOOP;
      -- (359) the arithmetic is shared with cerebro_reparto_cuadre (the conversation context): one function, one verdict
      SELECT * INTO v_s FROM cerebro_reparto_sumas(v_na, v_slots, v_dsp.base_gyd, v_dsp.tasa_cup, v_dsp.tasa_usd);
      v_con := v_s.con; v_ncup := v_s.ncup; v_nusd := v_s.nusd; v_sum_cup := v_s.sum_cup; v_sum_usd := v_s.sum_usd;
      v_sum_gyd := v_s.sum_gyd; v_tol := v_s.tol; v_rem := v_s.rem;
      v_suman := concat_ws(' + ', CASE WHEN v_ncup > 0 THEN trim_scale(v_sum_cup)::text || ' CUP' END,
                                  CASE WHEN v_nusd > 0 THEN trim_scale(v_sum_usd)::text || ' USD' END)
                 || CASE WHEN v_nusd > 0 THEN ', que equivalen a ' || trim_scale(round(v_sum_gyd))::text || ' GYD' ELSE '' END;
      IF v_s.estado = 'excede' THEN
        RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: el deposito verificado de este envio es ' || trim_scale(v_dsp.base_gyd)::text
          || ' GYD = ' || trim_scale(v_dsp.total_cup)::text || ' CUP (o ' || trim_scale(v_dsp.total_usd)::text
          || ' USD en tarjeta Clasica/Tropical) y los montos de las tarjetas suman ' || v_suman
          || '. Eso es mas de lo que deposito el cliente: preguntale como quiere repartir ese total entre las tarjetas. No se cambio nada.')::text;
        RETURN;
      ELSIF v_s.estado = 'faltan_montos' THEN
        v_aviso := CASE WHEN v_rem > v_tol
          THEN ' Del deposito verificado (' || trim_scale(v_dsp.base_gyd)::text || ' GYD = ' || trim_scale(v_dsp.total_cup)::text
               || ' CUP) ya asignaste ' || v_suman || ': quedan ' || trim_scale(round(v_rem * v_dsp.tasa_cup))::text
               || ' CUP para las demas tarjetas (o unos ' || trim_scale(floor(v_rem / v_dsp.tasa_usd))::text || ' USD si alguna es Clasica/Tropical).'
          ELSE ' Los montos que ya asignaste (' || v_suman || ') cubren todo el deposito verificado (' || trim_scale(v_dsp.base_gyd)::text
               || ' GYD): no queda nada para las tarjetas sin monto; preguntale al cliente como ajusta el reparto.' END;
      ELSIF v_s.estado = 'sobra' THEN
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
