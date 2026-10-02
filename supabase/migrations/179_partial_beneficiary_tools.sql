-- =====================================================================
-- 179 — beneficiary data is saved partial and in the order it arrives
--
-- Until now every beneficiary tool was all-or-nothing and every call REPLACED the previous
-- block: gestionar_beneficiario needed card AND phone, registrar_beneficiario_zelle name AND
-- account, registrar_reparto_multiple card + phone + amount for every person, and
-- cerebro_parsear_beneficiarios dropped a phone without a card, a Zelle without an account and
-- any reparto line with a gap. Yeny (op 99a4065d, 2026-09-28) gave two cards, the amounts and,
-- later, the phone for the second card: nothing of it was saved.
--
-- Owner rules (2026-10-01):
--   D1  arrival order: a card without a phone takes the next phone; a phone without a card
--       attaches to the next card without a phone.
--   D2  when in doubt the bot asks; the answer fixes what was saved and adds what is missing.
--
-- 1. cerebro_parsear_beneficiarios accepts partial blocks: "-" (or nothing) is a missing field.
--    Complete blocks parse exactly as before (checked against every production note).
-- 2. Three merge functions, the single place for these rules, PATCH semantics:
--      given fields overwrite; empty fields keep what is saved;
--      a different card starts without a phone (never inherits the old card's phone);
--      a different Zelle account starts without a holder name;
--      reparto slots are matched by position (1..3).
--    Each one writes the MERGED state as a new notes block (same storage as before, so the
--    panel, the sync trigger, the destination recalc and the calculator keep working) and
--    answers what is saved and what is missing, for the bot to ask.
--      cerebro_guardar_beneficiario(conv, nombre, tarjeta, celular, exec)
--      cerebro_guardar_zelle(conv, nombre, cuenta, exec)
--      cerebro_guardar_reparto(conv, t1, c1, m1, t2, c2, m2, t3, c3, m3, exec)
--    Several open operations: nothing is saved and the chat goes to a person, as before.
--
-- Guarded by supabase/staging/assertions/partial-beneficiary-tools.sql
-- ROLLBACK: ROLLBACK-179-partial-beneficiary-tools.sql (174's parser, drops the functions)
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

-- Normalizers shared by the three functions. NULL = not given; '!' = given but invalid.
CREATE OR REPLACE FUNCTION public.cerebro_norm_tarjeta(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN NULLIF(btrim(coalesce(p, '')), '') IS NULL THEN NULL
              WHEN regexp_replace(p, '[^0-9]', '', 'g') ~ '^[0-9]{16}$' THEN regexp_replace(p, '[^0-9]', '', 'g')
              ELSE '!' END
$$;

CREATE OR REPLACE FUNCTION public.cerebro_norm_celular_cu(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  -- A Cuban mobile: 8 digits starting with 5 or 63, also written +53 / 0053 in front.
  WITH d AS (SELECT regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') AS d)
  SELECT CASE WHEN NULLIF(btrim(coalesce(p, '')), '') IS NULL THEN NULL
              WHEN x ~ '^(5[0-9]{7}|63[0-9]{6})$' THEN x
              ELSE '!' END
    FROM (SELECT CASE WHEN length(d) = 10 AND left(d, 2) = '53' THEN right(d, 8)
                      WHEN length(d) = 12 AND left(d, 4) = '0053' THEN right(d, 8)
                      ELSE d END AS x FROM d) s
$$;

CREATE OR REPLACE FUNCTION public.cerebro_norm_cuenta_zelle(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  -- Same normalization as registrar_beneficiario_zelle (14-ago): a US number becomes 10 bare
  -- digits, an email is trimmed, anything else is kept as written.
  SELECT CASE
    WHEN NULLIF(btrim(coalesce(p, '')), '') IS NULL THEN NULL
    WHEN p LIKE '%@%' THEN btrim(p)
    WHEN btrim(p) LIKE '+%' AND btrim(p) NOT LIKE '+1%' THEN btrim(p)
    WHEN length(regexp_replace(p, '[^0-9]', '', 'g')) = 11 AND left(regexp_replace(p, '[^0-9]', '', 'g'), 1) = '1'
      THEN right(regexp_replace(p, '[^0-9]', '', 'g'), 10)
    WHEN length(regexp_replace(p, '[^0-9]', '', 'g')) = 10
     AND left(regexp_replace(p, '[^0-9]', '', 'g'), 1) BETWEEN '2' AND '9'
     AND left(regexp_replace(p, '[^0-9]', '', 'g'), 1) <> '5'
      THEN regexp_replace(p, '[^0-9]', '', 'g')
    ELSE btrim(p) END
$$;

-- Appends a beneficiary block to the remesa of this conversation (or opens one), the same
-- writes the tools did. Returns the deal and whether the operation was ambiguous.
CREATE OR REPLACE FUNCTION public.cerebro_escribir_bloque_beneficiario(p_conv uuid, p_op uuid, p_bloque text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_deal uuid;
BEGIN
  IF p_op IS NOT NULL THEN
    SELECT deal_id INTO v_deal FROM remittance_operations WHERE id = p_op;
  END IF;
  IF v_deal IS NOT NULL THEN
    UPDATE deals SET notes = COALESCE(notes, '') || E'\n---\n' || p_bloque, updated_at = now() WHERE id = v_deal;
    RETURN v_deal;
  END IF;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id, '78220927-0745-45a8-ba08-a1b33734dbf1',
         '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109', 'Remesa +' || c.phone, 0, 'GYD', p_bloque, 'open'
    FROM conversations v JOIN contacts c ON c.id = v.contact_id WHERE v.id = p_conv
  RETURNING id INTO v_deal;
  RETURN v_deal;
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_resolver_para_guardar(p_conv uuid, p_tool text, p_exec text, p_args jsonb,
                                                               OUT o_op uuid, OUT o_ambigua boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_res record;
BEGIN
  SELECT * INTO v_res FROM cerebro_resolver_operacion(p_conv, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);
  o_op := v_res.operation_id;
  o_ambigua := v_res.resultado = 'ambigua';
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments)
  VALUES (coalesce(p_exec, '') || ':' || p_tool || ':' || md5(p_args::text), p_tool, p_exec, p_conv, o_op, p_args)
  ON CONFLICT (idempotency_key) DO NOTHING;
  IF o_ambigua THEN
    PERFORM cerebro_registrar_derivacion(p_conv, 'Hay varias operaciones abiertas y el caso requiere revisión humana.',
                                         'operacion_ambigua', true);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario(p_conv uuid, p_nombre text, p_tarjeta text, p_celular text, p_exec text)
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
  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, 'gestionar_beneficiario', p_exec,
                                                        jsonb_build_array(p_nombre, p_tarjeta, p_celular));
  IF v_r.o_ambigua THEN
    RETURN QUERY SELECT NULL::uuid, 'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text;
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

CREATE OR REPLACE FUNCTION public.cerebro_guardar_zelle(p_conv uuid, p_nombre text, p_cuenta text, p_exec text)
RETURNS TABLE(deal_id uuid, accion text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a text := cerebro_norm_cuenta_zelle(p_cuenta);
  v_n text := NULLIF(btrim(coalesce(p_nombre, '')), '');
  v_r record; v_cur record; v_tiene boolean;
  v_acc text; v_name text; v_deal uuid; v_falta text;
BEGIN
  IF v_a IS NULL AND v_n IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, 'sin cambios: no llego ningun dato'::text; RETURN;
  END IF;
  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, 'registrar_beneficiario_zelle', p_exec,
                                                        jsonb_build_array(p_nombre, p_cuenta));
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
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_guardar_reparto(p_conv uuid,
    p_t1 text, p_c1 text, p_m1 text, p_t2 text, p_c2 text, p_m2 text, p_t3 text, p_c3 text, p_m3 text, p_exec text)
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

  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, 'registrar_reparto_multiple', p_exec,
                                                        jsonb_build_array(p_t1, p_c1, p_m1, p_t2, p_c2, p_m2, p_t3, p_c3, p_m3));
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

REVOKE ALL ON FUNCTION public.cerebro_escribir_bloque_beneficiario(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_resolver_para_guardar(uuid, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_guardar_reparto(uuid, text, text, text, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
