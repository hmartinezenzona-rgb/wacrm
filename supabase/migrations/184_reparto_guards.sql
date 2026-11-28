-- =====================================================================
-- 184 — a single-beneficiary write never overwrites a vigente reparto (staging; production 2026-10-02)
--
-- odd/tasks/reparto-guards.md, T1 (finding F2). Staging live test 2 (2026-10-02 03:36 UTC): the
-- reparto was saved with both cards; then gestionar_beneficiario (card 1 + the phone) wrote a single
-- cuban_card generation, the newest generation won, and card 2 and the amounts were lost. The same
-- function backs the bot tool and the deterministic node `Registrar beneficiario auto`, so both paths
-- are guarded here, below any prompt.
--
-- cerebro_guardar_beneficiario, when the operation has a vigente reparto (2-3 card slots):
--   * a card that is in the reparto: its slot is patched (phone), through cerebro_guardar_reparto;
--   * a lone phone: it completes the first slot still without a phone (owner rule D1, arrival order);
--   * anything else (a card not in the reparto, a phone when every slot has one, a name alone):
--     nothing is written and the answer sends the bot to registrar_reparto_multiple or to ask.
-- cerebro_guardar_reparto takes an optional operation and tool name (DEFAULT: the bot tool, 11
-- arguments as before), so the patch lands on the operation already resolved.
--
-- Guarded by supabase/staging/assertions/reparto-guards.sql (+ partial-beneficiary-tools.sql,
-- partial-beneficiary-auto.sql, which must stay ALL PASS).
-- ROLLBACK: ROLLBACK-184-reparto-guards.sql (179's reparto function, 180's beneficiary function)
-- =====================================================================

DROP FUNCTION public.cerebro_guardar_reparto(uuid, text, text, text, text, text, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.cerebro_guardar_reparto(p_conv uuid,
    p_t1 text, p_c1 text, p_m1 text, p_t2 text, p_c2 text, p_m2 text, p_t3 text, p_c3 text, p_m3 text, p_exec text,
    p_op uuid DEFAULT NULL, p_tool text DEFAULT 'registrar_reparto_multiple')
RETURNS TABLE(deal_id uuid, accion text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  IF NOT v_cambio THEN
    RETURN QUERY SELECT NULL::uuid, ('sin cambios: ese reparto ya estaba guardado'
      || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta ELSE '' END)::text;
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = v_r.o_op) INTO v_tiene;
  v_deal := cerebro_escribir_bloque_beneficiario(p_conv, v_r.o_op,
      CASE WHEN v_tiene THEN 'REPARTO ACTUALIZADO ENTRE VARIOS BENEFICIARIOS - reemplaza lo anterior'
           ELSE 'REPARTO ENTRE VARIOS BENEFICIARIOS' END || v_lineas);
  RETURN QUERY SELECT v_deal, ('reparto guardado: ' || v_resumen
    || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta || '. Pideselo al cliente, una pregunta por mensaje.' ELSE '. Completo.' END)::text;
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario(p_conv uuid, p_nombre text, p_tarjeta text, p_celular text, p_exec text, p_op uuid DEFAULT NULL, p_tool text DEFAULT 'gestionar_beneficiario')
RETURNS TABLE(deal_id uuid, accion text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_t text := cerebro_norm_tarjeta(p_tarjeta);
  v_c text := cerebro_norm_celular_cu(p_celular);
  v_n text := NULLIF(btrim(coalesce(p_nombre, '')), '');
  v_r record; v_cur record; v_tiene boolean;
  v_card text; v_phone text; v_name text; v_deal uuid; v_falta text;
  v_slots int; v_k int; v_libre int; v_tarjetas text;
BEGIN
  IF v_t = '!' OR v_c = '!' THEN
    RETURN QUERY SELECT NULL::uuid, ('ERROR: no se guardo nada. ' ||
      CASE WHEN v_t = '!' THEN 'La tarjeta tiene que tener 16 digitos. ' ELSE '' END ||
      CASE WHEN v_c = '!' THEN 'El celular cubano son 8 digitos y empieza por 5 o por 63. ' ELSE '' END ||
      'Pidele al cliente ese dato otra vez, con naturalidad.')::text;
    RETURN;
  END IF;
  IF v_t IS NULL AND v_c IS NULL AND v_n IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, 'sin cambios: no llego ningun dato'::text; RETURN;
  END IF;
  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, p_tool, p_exec,
                                                        jsonb_build_array(p_nombre, p_tarjeta, p_celular), p_op);
  IF v_r.o_ambigua THEN
    RETURN QUERY SELECT NULL::uuid, 'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text;
    RETURN;
  END IF;

  -- (184) A vigente reparto (2-3 card slots) is never replaced by a single beneficiary: the data
  -- completes the reparto slot it belongs to, or the bot is sent to the reparto tool.
  SELECT count(*), max(b.position) FILTER (WHERE b.card_number = v_t),
         min(b.position) FILTER (WHERE b.phone IS NULL),
         string_agg(coalesce(b.card_number, '(sin tarjeta)'), ', ' ORDER BY b.position)
    INTO v_slots, v_k, v_libre, v_tarjetas
    FROM remittance_beneficiaries b
   WHERE b.operation_id = v_r.o_op AND b.status = 'vigente'
     AND b.beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical') AND b.position BETWEEN 1 AND 3;
  IF v_slots >= 2 THEN
    IF v_t IS NULL AND v_c IS NOT NULL THEN
      v_k := v_libre;   -- D1: a lone phone completes the first card still without one
    END IF;
    IF v_k IS NULL THEN
      -- a card not in the reparto, a phone when every slot has one, or a name alone (no name per slot)
      RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: este envio es un REPARTO entre ' || v_slots
        || ' tarjetas (' || v_tarjetas || ')'
        || CASE WHEN v_t IS NOT NULL THEN ' y la tarjeta ' || v_t || ' no esta en el reparto'
                WHEN v_c IS NOT NULL THEN ' y todas ya tienen celular' ELSE '' END
        || '. Usa registrar_reparto_multiple, por posicion. Si no esta claro a que tarjeta va el dato, o si el'
        || ' cliente cambio de idea, preguntaselo con naturalidad.')::text;
      RETURN;
    END IF;
    RETURN QUERY SELECT * FROM cerebro_guardar_reparto(p_conv,
      CASE WHEN v_k = 1 THEN coalesce(v_t, '') ELSE '' END, CASE WHEN v_k = 1 THEN coalesce(v_c, '') ELSE '' END, '',
      CASE WHEN v_k = 2 THEN coalesce(v_t, '') ELSE '' END, CASE WHEN v_k = 2 THEN coalesce(v_c, '') ELSE '' END, '',
      CASE WHEN v_k = 3 THEN coalesce(v_t, '') ELSE '' END, CASE WHEN v_k = 3 THEN coalesce(v_c, '') ELSE '' END, '',
      p_exec, v_r.o_op, p_tool);
    RETURN;
  END IF;

  SELECT b.card_number, b.phone, b.name INTO v_cur
    FROM remittance_beneficiaries b
   WHERE b.operation_id = v_r.o_op AND b.status = 'vigente' AND b.beneficiary_type = 'cuban_card'
   ORDER BY b.block_index DESC LIMIT 1;

  -- D1: a different card starts without a phone; otherwise the given fields patch the saved ones.
  IF v_t IS NOT NULL AND v_cur.card_number IS NOT NULL AND v_t <> v_cur.card_number THEN
    v_card := v_t; v_phone := v_c; v_name := v_n;
  ELSE
    v_card := coalesce(v_t, v_cur.card_number);
    v_phone := coalesce(v_c, v_cur.phone);
    v_name := coalesce(v_n, v_cur.name);
  END IF;
  v_falta := concat_ws(' y ', CASE WHEN v_card IS NULL THEN 'la tarjeta' END, CASE WHEN v_phone IS NULL THEN 'el celular' END);

  IF v_card IS NOT DISTINCT FROM v_cur.card_number AND v_phone IS NOT DISTINCT FROM v_cur.phone
     AND v_name IS NOT DISTINCT FROM v_cur.name THEN
    RETURN QUERY SELECT NULL::uuid, ('sin cambios: esos datos ya estaban guardados'
      || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta ELSE '' END)::text;
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = v_r.o_op) INTO v_tiene;
  v_deal := cerebro_escribir_bloque_beneficiario(p_conv, v_r.o_op,
      CASE WHEN v_tiene THEN 'BENEFICIARIO ACTUALIZADO - reemplaza al anterior' ELSE 'BENEFICIARIO' END
      || CASE WHEN v_name IS NOT NULL THEN ' (' || v_name || ')' ELSE '' END
      || E'\nTarjeta: ' || coalesce(v_card, '-') || E'\nCelular: ' || coalesce(v_phone, '-'));
  RETURN QUERY SELECT v_deal, ('guardado: tarjeta ' || coalesce(v_card, '(falta)') || ', celular ' || coalesce(v_phone, '(falta)')
    || CASE WHEN v_name IS NOT NULL THEN ', nombre ' || v_name ELSE '' END
    || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta || '. Pideselo al cliente.' ELSE '. Completo.' END)::text;
END $$;

REVOKE ALL ON FUNCTION public.cerebro_guardar_reparto(uuid, text, text, text, text, text, text, text, text, text, text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text) FROM PUBLIC, anon, authenticated;
-- Production (2026-10-02) also ran, to keep its pre-184 ACL (postgres only):
--   REVOKE ALL ON FUNCTION public.cerebro_guardar_reparto(uuid, text, text, text, text, text, text, text, text, text, text, uuid, text) FROM service_role;
