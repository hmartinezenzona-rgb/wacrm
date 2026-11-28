-- =====================================================================
-- 306 -- Minimum of 20 USD for Clasica and Tropical
--
-- The owner set the minimum for tarjeta Clasica and Tropical at 20 USD. At the current 260 GYD/USD that is
-- 5,200 GYD. Until now both shared minimo_gyd_usd (13,000 GYD = 50 USD) with Zelle. Two config keys carry the
-- new values and the two functions that compute minima read them, falling back to the old keys if unset:
--   * cerebro_minimo_gyd: the per-operation minimum (deposit objective, split checks);
--   * cerebro_resolver_servicio: the mixed-deposit decisions.
-- Zelle keeps minimo_gyd_usd. The bot's minimums note reads the same keys from cerebro_config.
-- Assertion: supabase/staging/assertions/minimo-clasica-tropical.sql.
-- Rollback: ROLLBACK-306-minimo-clasica-tropical.sql.
-- =====================================================================

INSERT INTO public.cerebro_config (clave, valor, descripcion, actualizado)
VALUES ('minimo_gyd_clasica', '5200',
        'Minimo en GYD para tarjeta Clasica: 20 USD a 260 GYD/USD (306).', clock_timestamp()),
       ('minimo_gyd_tropical', '5200',
        'Minimo en GYD para tarjeta Tropical: 20 USD a 260 GYD/USD (306).', clock_timestamp())
ON CONFLICT (clave) DO UPDATE
   SET valor = EXCLUDED.valor, descripcion = EXCLUDED.descripcion, actualizado = clock_timestamp();

CREATE OR REPLACE FUNCTION public.cerebro_minimo_gyd(p_op uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_riel text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = p_op) THEN RETURN NULL; END IF;
  v_riel := cerebro_riel_op(p_op);
  RETURN CASE
    -- (272) Mexico: 13,000 GYD (50 USD at 260). Read from the service_type, not the rail: a Mexico operation has no rail of
    -- its own and its rail-less / stale delivery_method would fall to the CUP ELSE (5,000).
    WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_op) = 'mexico'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_mexico'), '')::numeric, 13000)
    WHEN v_riel = 'recarga'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200)
    -- (209) A combo: 25,000 GYD per recipient (at least one).
    WHEN v_riel = 'combo'
      THEN 25000 * greatest(1, (SELECT count(*) FROM remittance_beneficiaries b
                                 WHERE b.operation_id = p_op AND b.status = 'vigente'))
    -- (213) A visa extension: 5,000 GYD per person (the deposit says how many).
    WHEN v_riel = 'visa' THEN 5000
    -- (223) A mobile balance: one package (precio_saldo_gyd, 1,000 GYD).
    WHEN v_riel = 'saldo' THEN cerebro_saldo_precio()
    WHEN v_riel = 'clasica'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_clasica'), '')::numeric,
                    NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'tropical'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_tropical'), '')::numeric,
                    NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'zelle'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'efectivo_usd'
      THEN cerebro_minimo_efectivo_gyd()  -- (188) 100 USD x the calculator cash rate
    ELSE COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000)
  END;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_resolver_servicio(p_conv uuid, p_declarado text DEFAULT NULL::text, p_intencion text DEFAULT NULL::text, p_monto numeric DEFAULT NULL::numeric, p_ahora timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- services a declaration can name as a target (remesa is the default rail, never a target)
  c_destinos constant text[] := ARRAY['cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd', 'recarga', 'saldo', 'combo', 'visa', 'mexico'];
  c_rieles   constant text[] := ARRAY['cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd'];
  v_hoy      date;
  v_min_cup numeric; v_min_usd numeric; v_min_clasica numeric; v_min_tropical numeric; v_min_rec numeric; v_min_efe numeric; v_saldo numeric; v_min_mex numeric;
  v_pv numeric; v_pp numeric; v_promo boolean;
  v_row      text;
  v_decl     text;
  v_y        text;
  v_int      text;
  -- operations
  r          record;
  v_ops      jsonb := '[]'::jsonb;
  v_n_open   integer := 0;
  v_n_dep    integer := 0;
  v_grupo    uuid;
  v_holder   uuid;
  v_lone     uuid;
  v_subj     uuid;
  v_s        jsonb;
  v_tipo     text; v_riel text; v_status text; v_bloq text; v_x text; v_x_key text;
  v_dep_subj numeric := 0;
  -- evidence (data only)
  v_parcial  record;
  v_tarjeta boolean := false; v_zelle boolean := false; v_efec boolean := false;
  v_cel boolean := false; v_solo_cel boolean := false; v_data_rail text;
  v_d        numeric := 0; v_fuente text; v_es_precio boolean := false;
  -- decision
  v_min_x numeric; v_min_y numeric;
  v_accion   text := 'ninguna';
  v_motivo   text := 'sin_cambio';
  v_servicio text; v_en_curso text;
  v_dest     uuid; v_conv_a text;
  v_minimo   numeric; v_falta numeric;
  v_cancelar uuid[] := ARRAY[]::uuid[];
  v_adic     jsonb := '[]'::jsonb;
  v_permitido boolean; v_mensaje text; v_lbl_x text; v_lbl_y text;
  v_plan jsonb; v_dep_tot numeric;
  v_alt boolean := false;
BEGIN
  -- (283) the customer's words (cup, pesos, efectivo...) are understood here, not in the agent.
  p_declarado := _cerebro_servicio_clave(p_declarado);
  -- Initialised here, not in DECLARE: an error in a declaration is not caught by the EXCEPTION clause below.
  v_hoy := (p_ahora AT TIME ZONE 'America/Guyana')::date;
  v_min_cup := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_min_usd := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                        NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000);
  -- (306) Clasica y Tropical bajan a 20 USD; Zelle conserva el minimo de siempre.
  v_min_clasica := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_clasica'), '')::numeric, v_min_usd);
  v_min_tropical := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_tropical'), '')::numeric, v_min_usd);
  v_min_rec := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200);
  v_min_efe := cerebro_minimo_efectivo_gyd();
  -- (273) Mexico: same config key and default as cerebro_minimo_gyd (272): 13,000 GYD = 50 USD at 260.
  v_min_mex := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_mexico'), '')::numeric, 13000);
  v_saldo   := cerebro_saldo_precio();
  SELECT v.precio_gyd INTO v_pv FROM cerebro_promo_vigente(v_hoy) v;
  SELECT p.precio_gyd INTO v_pp FROM cerebro_promo_proxima(v_hoy) p;
  v_promo := v_pv IS NOT NULL OR v_pp IS NOT NULL;

  -- The declaration: the one named now, else the stored row (the latest declaration).
  SELECT d.servicio INTO v_row FROM cerebro_servicio_declarado d WHERE d.conversation_id = p_conv;
  v_decl := lower(btrim(coalesce(nullif(btrim(p_declarado), ''), v_row, '')));
  v_y    := nullif(v_decl, '');
  v_int  := coalesce(nullif(lower(btrim(p_intencion)), ''), 'cambiar');

  -- ---- open operations ---------------------------------------------------------------------------------------------
  FOR r IN
    SELECT o.id, o.status, o.service_type, o.quoted_source_amount, o.mixed_group_id, o.created_at,
           cerebro_riel_op(o.id) AS riel,
           EXISTS (SELECT 1 FROM remittance_operation_receipts x WHERE x.operation_id = o.id) AS recibo,
           EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.anulado_en IS NULL AND d.descartado_en IS NULL) AS dep,
           (SELECT k FROM unnest(ARRAY['delivery_method', 'service_type', 'quoted_destination_amount']) AS k
             WHERE coalesce(o.admin_locked_fields, '{}'::jsonb) ? k
               AND coalesce(o.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'automation:%' LIMIT 1) AS bloqueo,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
                    AND (nullif(b.card_number, '') IS NOT NULL OR b.beneficiary_type IN ('clasica', 'tropical', 'multiple_distribution'))) AS b_tarjeta,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
                    AND (nullif(b.zelle_account, '') IS NOT NULL OR b.beneficiary_type = 'zelle')) AS b_zelle,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
                    AND b.beneficiary_type = 'efectivo_usd') AS b_efec,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
                    AND nullif(b.phone, '') IS NOT NULL
                    AND b.beneficiary_type NOT IN ('mexico_cuenta', 'mexico_retiro')) AS b_cel
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at, o.id
  LOOP
    v_n_open := v_n_open + 1;
    v_ops := v_ops || jsonb_build_object(
      'id', r.id,
      'servicio', CASE WHEN r.service_type = 'remesa' THEN coalesce(r.riel, 'remesa') ELSE r.service_type END,
      'tipo', r.service_type, 'status', r.status, 'rail', r.riel,
      'deposito', CASE WHEN r.recibo OR r.dep THEN coalesce(r.quoted_source_amount, 0) ELSE 0 END,
      'tiene_deposito', r.recibo OR r.dep,
      -- (293) the money the operation holds, and the amount agreed for it while it holds none (the bot decides, the database validates the money)
      'dinero_gyd', CASE WHEN r.recibo OR r.dep THEN coalesce(r.quoted_source_amount, 0) ELSE 0 END,
      'monto_acordado_gyd', CASE WHEN NOT (r.recibo OR r.dep) THEN nullif(r.quoted_source_amount, 0) ELSE _cerebro_monto_acordado_previo(r.id) END,
      'vacia', NOT (r.recibo OR r.dep) AND (coalesce(r.quoted_source_amount, 0) = 0 OR _cerebro_op_monto_acordado(r.id))
               AND r.bloqueo IS NULL AND r.status IN ('collecting_information', 'awaiting_deposit'),
      'grupo', r.mixed_group_id, 'bloqueo_humano', r.bloqueo,
      'tarjeta', r.b_tarjeta, 'zelle', r.b_zelle, 'efectivo', r.b_efec, 'celular', r.b_cel,
      'creado', r.created_at);
    IF r.mixed_group_id IS NOT NULL THEN v_grupo := coalesce(v_grupo, r.mixed_group_id); END IF;
    IF r.recibo OR r.dep THEN
      v_n_dep := v_n_dep + 1; v_holder := coalesce(v_holder, r.id);
    END IF;
    v_lone := r.id;
  END LOOP;

  -- The holder is the subject; with no deposit at all, the lone open operation is the subject.
  v_subj := CASE WHEN v_n_dep = 1 THEN v_holder WHEN v_n_dep = 0 AND v_n_open = 1 THEN v_lone END;
  -- (283) Several open operations and no deposit: the request names a RAIL service, so the target is the operation of its SERVICE. An operation that is
  -- already of the requested service means there is nothing to change; otherwise the single plain remesa is the one that changes (a Mexico, recharge,
  -- combo, visa or balance operation is never re-typed by another service's request). Two remesas stay ambiguous.
  IF v_subj IS NULL AND v_n_dep = 0 AND v_n_open > 1 AND v_grupo IS NULL
     AND lower(btrim(coalesce(nullif(btrim(p_declarado), ''), v_row, ''))) = ANY (c_rieles) THEN
    SELECT (e ->> 'id')::uuid INTO v_subj FROM jsonb_array_elements(v_ops) e
     WHERE e ->> 'servicio' = lower(btrim(coalesce(nullif(btrim(p_declarado), ''), v_row))) ORDER BY e ->> 'creado', e ->> 'id' LIMIT 1;
    IF v_subj IS NULL AND (SELECT count(*) FROM jsonb_array_elements(v_ops) e WHERE e ->> 'tipo' = 'remesa') = 1 THEN
      SELECT (e ->> 'id')::uuid INTO v_subj FROM jsonb_array_elements(v_ops) e WHERE e ->> 'tipo' = 'remesa';
      v_alt := true;
    END IF;
  END IF;
  IF v_subj IS NOT NULL THEN
    SELECT e INTO v_s FROM jsonb_array_elements(v_ops) e WHERE e ->> 'id' = v_subj::text;
    v_tipo := v_s ->> 'tipo'; v_status := v_s ->> 'status'; v_bloq := v_s ->> 'bloqueo_humano';
    v_x := v_s ->> 'servicio'; v_dep_subj := coalesce((v_s ->> 'deposito')::numeric, 0);
    v_riel := CASE WHEN v_tipo = 'remesa' THEN v_s ->> 'rail' END;
  END IF;

  -- ---- data evidence (never message text) ---------------------------------------------------------------------------
  SELECT * INTO v_parcial FROM cerebro_beneficiario_parcial bp WHERE bp.conversation_id = p_conv;
  v_tarjeta := coalesce(nullif(v_parcial.tarjeta, ''), '') <> ''
               OR coalesce((v_s ->> 'tarjeta')::boolean, false);
  -- (parent review) a card RAIL or a card-typed recipient without a card number is not card data: the system saves a
  -- lone Cuban mobile as a cuban_card recipient (notes_parse, the real 1232671b shape). Only a card number counts.
  v_zelle := coalesce(coalesce(nullif(v_parcial.zelle_cuenta, ''), nullif(v_parcial.zelle_nombre, ''),
                               nullif(v_parcial.zelle_nombre_cuenta, '')) IS NOT NULL, false)
             OR coalesce((v_s ->> 'zelle')::boolean, false) OR coalesce(v_riel = 'zelle', false);
  v_efec := coalesce((v_s ->> 'efectivo')::boolean, false) OR coalesce(v_riel = 'efectivo_usd', false);
  v_cel  := coalesce(nullif(v_parcial.celular, ''), '') <> '' OR coalesce((v_s ->> 'celular')::boolean, false);
  v_solo_cel := v_cel AND NOT (v_tarjeta OR v_zelle OR v_efec);
  v_data_rail := CASE WHEN v_zelle THEN 'zelle' WHEN v_efec THEN 'efectivo_usd' ELSE 'cuban_card' END;
  v_x_key := CASE WHEN v_tipo = 'remesa' THEN coalesce(CASE WHEN v_riel = ANY (c_rieles) THEN v_riel END, v_data_rail)
                  ELSE v_tipo END;

  -- The deposit the decision is about: the holder's, else the amount registered now.
  v_d := CASE WHEN v_dep_subj > 0 THEN v_dep_subj WHEN coalesce(p_monto, 0) > 0 THEN p_monto ELSE 0 END;
  v_fuente := CASE WHEN v_dep_subj > 0 THEN 'operacion' WHEN coalesce(p_monto, 0) > 0 THEN 'parametro' END;
  v_es_precio := v_d > 0 AND v_pv IS NOT NULL AND mod(v_d, v_pv) = 0;

  v_en_curso := v_x;
  v_servicio := v_x;

  <<flow>>
  BEGIN
    -- R0 validation (facts about the request, not about the customer's words)
    IF v_y IS NOT NULL AND NOT (v_y = ANY (c_destinos)) THEN v_motivo := 'servicio_invalido'; EXIT flow; END IF;
    IF v_int NOT IN ('cambiar', 'agregar') THEN v_motivo := 'intencion_invalida'; EXIT flow; END IF;

    -- R1 a mixed group changes only through repartir_envio.
    IF v_grupo IS NOT NULL THEN v_motivo := 'grupo_mixto'; EXIT flow; END IF;

    -- R2 one deposit per operation is never a mixed send; without a holder the subject is unknown.
    IF v_n_dep > 1 THEN v_motivo := 'depositos_separados'; v_servicio := NULL; v_en_curso := NULL; EXIT flow; END IF;
    IF v_subj IS NULL AND v_n_open > 1 THEN v_motivo := 'varias_operaciones'; v_servicio := NULL; v_en_curso := NULL; EXIT flow; END IF;

    -- R3 a person fixed it, or the money is moving.
    IF v_subj IS NOT NULL THEN
      IF v_bloq IS NOT NULL THEN v_motivo := 'bloqueada'; EXIT flow; END IF;
      IF v_status IN ('transferring', 'incident') THEN v_motivo := 'estado_no_permite'; EXIT flow; END IF;
    END IF;

    -- R4 a recarga needs a live or announced promo (207/211).
    IF v_y = 'recarga' AND NOT v_promo THEN v_motivo := 'recarga_sin_promo'; EXIT flow; END IF;

    -- R5-R7 a declared target Y.
    IF v_y IS NOT NULL THEN
      v_min_y := CASE v_y
                   WHEN 'zelle' THEN v_min_usd WHEN 'clasica' THEN v_min_clasica WHEN 'tropical' THEN v_min_tropical
                   WHEN 'efectivo_usd' THEN v_min_efe
                   WHEN 'recarga' THEN coalesce(v_pv, v_pp, v_min_rec)
                   WHEN 'saldo' THEN v_saldo WHEN 'visa' THEN 5000 WHEN 'combo' THEN 25000
                   WHEN 'mexico' THEN v_min_mex
                   ELSE v_min_cup END;

      IF v_subj IS NULL THEN
        -- R7 no holder: Y is the service of a new operation.
        v_servicio := v_y;
        IF v_d > 0 AND v_d < v_min_y THEN
          v_motivo := 'deposito_bajo_minimo'; v_minimo := v_min_y; v_falta := v_min_y - v_d;
        ELSE
          v_motivo := 'nueva_operacion';
        END IF;
        EXIT flow;
      END IF;

      -- R6 the holder is already of service Y.
      IF v_x = v_y THEN v_motivo := 'sin_cambio'; EXIT flow; END IF;

      -- R5 the holder is of another service.
      v_min_x := CASE v_x_key
                   WHEN 'zelle' THEN v_min_usd WHEN 'clasica' THEN v_min_clasica WHEN 'tropical' THEN v_min_tropical
                   WHEN 'efectivo_usd' THEN v_min_efe
                   WHEN 'recarga' THEN coalesce(v_pv, v_pp, v_min_rec)
                   WHEN 'saldo' THEN v_saldo WHEN 'visa' THEN 5000 WHEN 'combo' THEN 25000
                   WHEN 'mexico' THEN v_min_mex
                   ELSE v_min_cup END;
      IF v_int = 'agregar' THEN
        IF v_d >= v_min_x + v_min_y THEN
          v_accion := 'mixto'; v_motivo := 'deposito_cubre_ambos'; v_dest := v_subj; v_servicio := v_y;
          v_adic := jsonb_build_array(jsonb_build_object('servicio', v_y, 'monto', v_min_y));
        ELSE
          v_accion := 'aparte'; v_motivo := 'adicional_aparte'; v_servicio := v_y; v_minimo := v_min_y;
        END IF;
        EXIT flow;
      END IF;

      -- cambiar
      -- (283) a RAIL target (zelle / clasica / tropical / cuban_card / efectivo_usd) with no money registered at all: nothing to cover yet, the
      -- minimum is checked when the deposit arrives. recarga / saldo / combo / visa / mexico keep needing the money first (265, 276).
      IF (v_d = 0 AND v_y = ANY (c_rieles)) OR v_d >= v_min_y THEN
        v_accion := 'convertir'; v_motivo := 'declarado'; v_dest := v_subj; v_conv_a := v_y; v_servicio := v_y;
        v_cancelar := coalesce(ARRAY(SELECT (e ->> 'id')::uuid FROM jsonb_array_elements(v_ops) e
                                      WHERE (e ->> 'vacia')::boolean
                                        AND (e ->> 'id')::uuid IS DISTINCT FROM v_subj
                                        AND e ->> 'servicio' IS DISTINCT FROM v_x), ARRAY[]::uuid[]);
        IF v_alt THEN v_cancelar := ARRAY[]::uuid[]; END IF;
      ELSE
        v_motivo := 'deposito_bajo_minimo'; v_minimo := v_min_y; v_falta := v_min_y - v_d;
      END IF;
      EXIT flow;
    END IF;

    -- R8 no declaration: the recipient is phone-only and the deposit is whole promo prices (Q1).
    IF v_solo_cel AND v_pv IS NOT NULL AND v_es_precio AND (v_subj IS NULL OR v_tipo = 'remesa') THEN
      v_motivo := 'monto_precio_y_celular'; v_servicio := 'recarga';
      IF v_subj IS NOT NULL THEN
        v_accion := 'convertir'; v_dest := v_subj; v_conv_a := 'recarga';
        v_cancelar := coalesce(ARRAY(SELECT (e ->> 'id')::uuid FROM jsonb_array_elements(v_ops) e
                                      WHERE (e ->> 'vacia')::boolean
                                        AND (e ->> 'id')::uuid IS DISTINCT FROM v_subj
                                        AND e ->> 'servicio' IS DISTINCT FROM v_x), ARRAY[]::uuid[]);
      END IF;
      EXIT flow;
    END IF;

    -- R9 default: nothing to change.
  END;

  -- (277) The split the agent planned before the deposit (facts for the Decisor): parts with their USD, the planned total, the money
  -- registered so far and the difference.
  SELECT coalesce(sum((e ->> 'deposito')::numeric), 0) INTO v_dep_tot FROM jsonb_array_elements(v_ops) e WHERE (e ->> 'tiene_deposito')::boolean;
  SELECT jsonb_build_object(
           'partes', (SELECT jsonb_agg(jsonb_build_object('servicio', x ->> 'servicio', 'monto_gyd', (x ->> 'monto_gyd')::numeric,
                                                        'usd', _cerebro_usd_parte(x ->> 'servicio', (x ->> 'monto_gyd')::numeric)) ORDER BY ord)
                        FROM jsonb_array_elements(pl.partes) WITH ORDINALITY t(x, ord)),
           'total_gyd', pl.total_gyd, 'deposito_gyd', v_dep_tot, 'diferencia_gyd', v_dep_tot - pl.total_gyd,
           'coincide', v_dep_tot = pl.total_gyd)
    INTO v_plan FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = p_conv;

  -- Plain-Spanish sentence for the bot (labels only; the numbers come from the rules above).
  v_lbl_y := (SELECT t.l FROM (VALUES ('cuban_card', 'la tarjeta CUP'), ('clasica', 'la tarjeta clásica'),
                                      ('tropical', 'la tarjeta tropical'), ('zelle', 'Zelle'),
                                      ('efectivo_usd', 'efectivo en USD'), ('recarga', 'la recarga'),
                                      ('saldo', 'el saldo móvil'), ('combo', 'el combo'),
                                      ('visa', 'la extensión de visa'), ('mexico', 'el envío a México'), ('remesa', 'la remesa')) AS t(k, l)
               WHERE t.k = coalesce(v_y, v_conv_a));
  v_lbl_x := (SELECT t.l FROM (VALUES ('cuban_card', 'la tarjeta CUP'), ('clasica', 'la tarjeta clásica'),
                                      ('tropical', 'la tarjeta tropical'), ('zelle', 'Zelle'),
                                      ('efectivo_usd', 'efectivo en USD'), ('recarga', 'la recarga'),
                                      ('saldo', 'el saldo móvil'), ('combo', 'el combo'),
                                      ('visa', 'la extensión de visa'), ('mexico', 'el envío a México'), ('remesa', 'la remesa')) AS t(k, l)
               WHERE t.k = v_x);
  v_mensaje := CASE v_motivo
    WHEN 'grupo_mixto' THEN 'Esta operación está en un envío mixto: los cambios se hacen con repartir_envio.'
    WHEN 'depositos_separados' THEN 'Hay varias operaciones con depósito propio y no se cambian juntas.'
    WHEN 'varias_operaciones' THEN 'Hay varias operaciones abiertas sin depósito: no se sabe a cuál aplicar el cambio.'
    WHEN 'bloqueada' THEN 'Un dato de esta operación lo fijó una persona: el bot no lo cambia.'
    WHEN 'estado_no_permite' THEN 'La operación está en un estado que no permite cambiar el servicio.'
    WHEN 'recarga_sin_promo' THEN 'No hay promoción de recarga vigente ni anunciada.'
    WHEN 'deposito_bajo_minimo' THEN 'No alcanza para ' || v_lbl_y || ': el mínimo es '
                                     || to_char(v_minimo, 'FM999,999,999') || ' GYD y faltan '
                                     || to_char(v_falta, 'FM999,999,999') || ' GYD.'
    WHEN 'servicio_invalido' THEN 'El servicio indicado no es válido.'
    WHEN 'intencion_invalida' THEN 'La intención indicada no es válida.'
    ELSE CASE v_accion
           WHEN 'convertir' THEN 'Se pasa la operación a ' || v_lbl_y || '.'
           WHEN 'mixto' THEN 'El depósito cubre ' || v_lbl_x || ' y ' || v_lbl_y || '.'
           WHEN 'aparte' THEN 'Se abre una operación aparte para ' || v_lbl_y || ': necesita su propio depósito de al menos '
                              || to_char(v_minimo, 'FM999,999,999') || ' GYD.'
           ELSE CASE v_motivo
                  WHEN 'nueva_operacion' THEN
                    CASE WHEN v_int = 'agregar'
                         THEN 'Anotado: se agrega ' || coalesce(v_lbl_y, 'ese servicio') || ' como operación nueva; todavía no hay otra operación abierta y se abre con sus datos o al repartir el depósito.'
                         ELSE 'Anotado: ' || coalesce(v_lbl_y, 'ese servicio') || ' será la operación; todavía no hay ninguna abierta y se abre con sus datos o con su depósito.' END
                  WHEN 'sin_cambio' THEN
                    CASE WHEN v_lbl_x IS NOT NULL THEN 'La operación ya es ' || v_lbl_x || ': no hay nada que cambiar.'
                         ELSE 'No hay ningún cambio de servicio que aplicar.' END
                  ELSE NULL
                END
         END
  END;
  -- (279) The agent always gets a sentence it can use.
  v_mensaje := coalesce(v_mensaje, 'No hay ningún cambio de servicio que aplicar.');
  v_permitido := v_accion <> 'ninguna' OR v_motivo IN ('sin_cambio', 'nueva_operacion');

  RETURN jsonb_build_object(
    'version', 2,
    'servicio', v_servicio,
    'en_curso', v_en_curso,
    'accion', v_accion,
    'permitido', v_permitido,
    'motivo', v_motivo,
    'mensaje', v_mensaje,
    'minimo_gyd', v_minimo,
    'faltante_gyd', v_falta,
    'destino_operacion', v_dest,
    'convertir_a', v_conv_a,
    'cancelar', to_jsonb(v_cancelar),
    'grupo_mixto', v_grupo,
    'adicionales', v_adic,
    'operaciones', v_ops,
    'evidencia', jsonb_build_object(
      'deposito', v_d,
      'fuente', v_fuente,
      'monto_igual_precio', v_es_precio,
      'solo_celular', v_solo_cel,
      'tarjeta', v_tarjeta,
      'zelle', v_zelle,
      'promo', jsonb_build_object('vigente', v_pv IS NOT NULL, 'proxima', v_pp IS NOT NULL),
      'declarado', nullif(v_decl, ''),
      'intencion', CASE WHEN v_y IS NOT NULL THEN v_int END),
    'reparto_planeado', v_plan);
EXCEPTION WHEN OTHERS THEN
  -- Fail open: the bot keeps working without the resolver's answer.
  RETURN jsonb_build_object(
    'version', 2, 'servicio', NULL, 'en_curso', NULL, 'accion', 'ninguna', 'permitido', false, 'motivo', 'error',
    'mensaje', 'No se pudo comprobar el servicio en este momento: no se cambió nada.', 'minimo_gyd', NULL, 'faltante_gyd', NULL, 'destino_operacion', NULL, 'convertir_a', NULL,
    'cancelar', '[]'::jsonb, 'grupo_mixto', NULL, 'adicionales', '[]'::jsonb, 'operaciones', '[]'::jsonb,
    'evidencia', '{}'::jsonb, 'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200));
END $function$;
