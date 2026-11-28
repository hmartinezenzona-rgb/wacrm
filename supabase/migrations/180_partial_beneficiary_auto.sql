-- =====================================================================
-- 180 — the deterministic registration nodes save partial data too
--
-- 179 made the bot's tools save beneficiary data partial and in arrival order. The two
-- deterministic nodes (`Registrar beneficiario auto`, `Registrar zelle auto`) still waited for the
-- complete pair, so a card photo without its phone stayed in cerebro_beneficiario_parcial only, and
-- that memory paired a NEW card with the OLD card's phone (COALESCE across bursts).
--
--   cerebro_guardar_beneficiario_auto(conv, burst card, burst phone, accumulated card, accumulated phone, exec)
--   cerebro_guardar_zelle_auto(conv, accumulated holder, accumulated account, exec)
--     * an open remesa (resolved by card / account, cerebro_resolver_operacion_beneficiario, as the
--       nodes always did): what arrived is saved at once, partial, with 179's D1 rules (a new card
--       never inherits the old phone, the phone that arrives later completes the saved card);
--     * no open remesa: one is opened only with the complete pair, as before, so a lone Cuban phone
--       (a recarga, for instance) never opens a remesa;
--     * several open remesas the resolver cannot tell apart: as before, nothing is saved and the chat
--       goes to a person.
--   cerebro_resolver_para_guardar / cerebro_guardar_beneficiario / cerebro_guardar_zelle take an
--   optional operation (DEFAULT NULL: the bot tools call them exactly as in 179).
--
-- Guarded by supabase/staging/assertions/partial-beneficiary-auto.sql (+ partial-beneficiary-tools.sql)
-- ROLLBACK: ROLLBACK-180-partial-beneficiary-auto.sql (179's three functions, drops the auto ones)
-- =====================================================================

DROP FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text);
DROP FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text);
DROP FUNCTION public.cerebro_resolver_para_guardar(uuid, text, text, jsonb);
-- (the reparto function calls the resolver with 4 arguments: kept working by the DEFAULT below)

CREATE OR REPLACE FUNCTION public.cerebro_resolver_para_guardar(p_conv uuid, p_tool text, p_exec text, p_args jsonb, p_op uuid DEFAULT NULL,
                                                               OUT o_op uuid, OUT o_ambigua boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_res record;
BEGIN
  -- (180) The deterministic nodes resolve the operation themselves (by card / account) and pass it.
  IF p_op IS NOT NULL THEN
    o_op := p_op; o_ambigua := false;
  ELSE
    SELECT * INTO v_res FROM cerebro_resolver_operacion(p_conv, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);
    o_op := v_res.operation_id;
    o_ambigua := v_res.resultado = 'ambigua';
  END IF;
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments)
  VALUES (coalesce(p_exec, '') || ':' || p_tool || ':' || md5(p_args::text), p_tool, p_exec, p_conv, o_op, p_args)
  ON CONFLICT (idempotency_key) DO NOTHING;
  IF o_ambigua THEN
    PERFORM cerebro_registrar_derivacion(p_conv, 'Hay varias operaciones abiertas y el caso requiere revisión humana.',
                                         'operacion_ambigua', true);
  END IF;
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

CREATE OR REPLACE FUNCTION public.cerebro_guardar_zelle(p_conv uuid, p_nombre text, p_cuenta text, p_exec text, p_op uuid DEFAULT NULL, p_tool text DEFAULT 'registrar_beneficiario_zelle')
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
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario_auto(p_conv uuid, p_tarjeta text, p_celular text,
                                                                   p_tarjeta_acum text, p_celular_acum text, p_exec text)
RETURNS TABLE(deal_id uuid, accion text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_t text := cerebro_norm_tarjeta(p_tarjeta);
  v_c text := cerebro_norm_celular_cu(p_celular);
  v_ta text := cerebro_norm_tarjeta(p_tarjeta_acum);
  v_ca text := cerebro_norm_celular_cu(p_celular_acum);
  v_res record; v_out record;
BEGIN
  SELECT * INTO v_res FROM cerebro_resolver_operacion_beneficiario(p_conv,
           ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'],
           coalesce(NULLIF(v_t, '!'), NULLIF(v_ta, '!'), ''));
  IF v_res.operation_id IS NOT NULL THEN
    -- An open remesa: what arrived in this burst, partial, D1 (179).
    SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', coalesce(p_tarjeta, ''), coalesce(p_celular, ''), p_exec, v_res.operation_id, 'Registrar beneficiario auto');
  ELSIF v_res.resultado = 'ninguna' THEN
    -- No open remesa: only the complete pair opens one (as before).
    IF v_ta IS NOT NULL AND v_ta <> '!' AND v_ca IS NOT NULL AND v_ca <> '!' THEN
      SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', v_ta, v_ca, p_exec, NULL, 'Registrar beneficiario auto');
    ELSE
      RETURN QUERY SELECT NULL::uuid, 'sin envio abierto: se espera el dato que falta para abrirlo'::text; RETURN;
    END IF;
  ELSE
    -- Several open remesas the resolver cannot tell apart: the 179 path derives to a person.
    SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', coalesce(p_tarjeta, ''), coalesce(p_celular, ''), p_exec, NULL, 'Registrar beneficiario auto');
  END IF;
  IF v_out.accion LIKE '%Completo.%' THEN
    DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = p_conv;
  END IF;
  RETURN QUERY SELECT v_out.deal_id, v_out.accion;
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_guardar_zelle_auto(p_conv uuid, p_nombre text, p_cuenta text, p_exec text)
RETURNS TABLE(deal_id uuid, accion text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a text := cerebro_norm_cuenta_zelle(p_cuenta);
  v_n text := NULLIF(btrim(coalesce(p_nombre, '')), '');
  v_res record;
BEGIN
  SELECT * INTO v_res FROM cerebro_resolver_operacion_beneficiario(p_conv,
           ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'], coalesce(v_a, ''));
  IF v_res.operation_id IS NOT NULL THEN
    RETURN QUERY SELECT * FROM cerebro_guardar_zelle(p_conv, coalesce(p_nombre, ''), coalesce(p_cuenta, ''), p_exec, v_res.operation_id, 'Registrar zelle auto');
  ELSIF v_res.resultado = 'ninguna' THEN
    IF v_a IS NOT NULL AND v_n IS NOT NULL THEN
      RETURN QUERY SELECT * FROM cerebro_guardar_zelle(p_conv, p_nombre, p_cuenta, p_exec, NULL, 'Registrar zelle auto');
    ELSE
      RETURN QUERY SELECT NULL::uuid, 'sin envio abierto: se espera el dato que falta para abrirlo'::text;
    END IF;
  ELSE
    RETURN QUERY SELECT * FROM cerebro_guardar_zelle(p_conv, coalesce(p_nombre, ''), coalesce(p_cuenta, ''), p_exec, NULL, 'Registrar zelle auto');
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.cerebro_resolver_para_guardar(uuid, text, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario_auto(uuid, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_guardar_zelle_auto(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
