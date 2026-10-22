-- =====================================================================
-- 265 -- service resolver v2: the agent declares intent, the database checks money, data and state (staging first)
--
-- odd/tasks/service-resolution.md, REDESIGN 2026-10-22 (binding). Word lists, question regexes and word recency are
-- gone: this migration never reads a customer message. Intent comes from the agent through two calls:
--   cerebro_declarar_servicio(p_conv, p_servicio, p_actor)  the service the customer states before paying (one row per
--                                                            conversation, the latest declaration wins; cleared by the
--                                                            trigger when the conversation's last open operation closes)
--   cerebro_resolver_servicio(p_conv, p_declarado, p_intencion, p_monto, p_ahora)
--       p_declarado   service named by the agent now; overrides the stored declaration
--       p_intencion   'cambiar' (change of mind; default when the target comes from a declaration) or 'agregar' (addition)
--       p_monto       a deposit not registered yet (used only when no operation holds a deposit)
--       p_ahora       promo date reference (Guyana day)
-- The resolver is PURE (it never writes) and fail-open: any error returns version 2, accion 'ninguna', permitido false.
--
-- Terms. HOLDER = the subject operation: the only open operation holding a deposit (receipt or depositos_mmg row), else
-- the only open operation. D = the holder's deposit, else p_monto. Phone-only = a mobile and no card, Zelle or cash data.
-- SERVICE X of an operation = its rail for a remesa ('remesa' when it has none), its type otherwise. MIN(s) = the minimum
-- the deposit must meet for service s: CUP card 5,000 (config minimo_gyd_cup), USD cards and Zelle 13,000 (config
-- minimo_gyd_usd / zelle_minimo_gyd), cash per cerebro_minimo_efectivo_gyd, recarga = the live or announced promo price,
-- saldo = cerebro_saldo_precio(), visa 5,000, combo 25,000. A remesa with no rail is priced as its data rail (default CUP).
--
-- DECISION TABLE (first match wins; motivo is the rule that fired):
--   R0  validation        p_declarado not a destination (remesa is the default rail, never a target) -> servicio_invalido
--                         p_intencion not cambiar/agregar                                             -> intencion_invalida
--   R1  mixed group       an open operation is in a mixed group               -> ninguna grupo_mixto (repartir_envio)
--   R2  deposits          several open operations each hold a deposit          -> ninguna depositos_separados (Q5)
--                         several open operations and no holder               -> ninguna varias_operaciones
--   R3  protected         holder human-locked                                 -> ninguna bloqueada
--                         holder transferring or incident                     -> ninguna estado_no_permite
--                         (ready_to_transfer, a verified deposit, IS convertible: Q6)
--   R4  recarga promo     Y = recarga and no promo live or announced          -> ninguna recarga_sin_promo
--   R5  holder, other service (X != Y)
--         agregar: D >= MIN(X) + MIN(Y)  -> mixto deposito_cubre_ambos (adicionales: Y at MIN(Y); destino = holder)
--                  else                  -> aparte adicional_aparte (new operation awaiting its own deposit; holder untouched)
--         cambiar: D >= MIN(Y)           -> convertir declarado (destino = holder, convertir_a Y, cancelar = empty
--                                           operations of another service, Q3)
--                  else                  -> ninguna deposito_bajo_minimo (minimo_gyd, faltante_gyd)
--   R6  holder already Y                  -> ninguna sin_cambio
--   R7  no holder, Y set                  -> ninguna deposito_bajo_minimo (D < MIN(Y)), else ninguna nueva_operacion
--                                           (Y is the service of the new operation)
--   R8  no declaration, phone-only        remesa holder (or no holder) with D a whole multiple of the LIVE promo price (Q1):
--                                           convertir monto_precio_y_celular to recarga (with holder), or
--                                           ninguna monto_precio_y_celular for a new recarga operation
--   R9  default                           -> ninguna sin_cambio
-- Output (version 2): version, servicio, en_curso, accion {ninguna, convertir, mixto, aparte}, permitido, motivo, mensaje
-- (short Spanish sentence for the bot, NULL when there is nothing to say), minimo_gyd, faltante_gyd, destino_operacion,
-- convertir_a, cancelar[], grupo_mixto, adicionales[], operaciones[], evidencia{}.
--
-- Guarded by supabase/staging/assertions/resolver-servicio.sql. ROLLBACK: ROLLBACK-265-service-resolver.sql
-- =====================================================================

CREATE TABLE public.cerebro_servicio_declarado (
  conversation_id uuid PRIMARY KEY REFERENCES conversations (id) ON DELETE CASCADE,
  servicio text NOT NULL CHECK (servicio IN ('remesa', 'cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd',
                                              'recarga', 'saldo', 'combo', 'visa')),
  declarado_at timestamptz NOT NULL DEFAULT now(),
  actor text
);

ALTER TABLE public.cerebro_servicio_declarado ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cerebro_servicio_declarado FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.cerebro_servicio_declarado TO service_role;

-- The agent's declaration: one row per conversation, the latest one wins.
CREATE OR REPLACE FUNCTION public.cerebro_declarar_servicio(
  p_conv uuid,
  p_servicio text,
  p_actor text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_servicio text := lower(btrim(coalesce(p_servicio, '')));
BEGIN
  IF v_servicio NOT IN ('remesa', 'cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd', 'recarga', 'saldo', 'combo', 'visa') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'servicio_invalido');
  END IF;
  INSERT INTO public.cerebro_servicio_declarado (conversation_id, servicio, declarado_at, actor)
  VALUES (p_conv, v_servicio, now(), p_actor)
  ON CONFLICT (conversation_id) DO UPDATE
    SET servicio = EXCLUDED.servicio, declarado_at = EXCLUDED.declarado_at, actor = EXCLUDED.actor;
  RETURN jsonb_build_object('ok', true, 'servicio', v_servicio);
END $function$;

-- When an operation closes and the conversation has no other open operation, its declaration is cleared.
CREATE OR REPLACE FUNCTION public.cerebro_limpiar_servicio_declarado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status IN ('completed', 'cancelled') AND OLD.status IS DISTINCT FROM NEW.status
     AND NEW.conversation_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM remittance_operations o
                      WHERE o.conversation_id = NEW.conversation_id AND o.id <> NEW.id
                        AND o.status NOT IN ('completed', 'cancelled')) THEN
    DELETE FROM public.cerebro_servicio_declarado WHERE conversation_id = NEW.conversation_id;
  END IF;
  RETURN NULL;
END $function$;

DROP TRIGGER IF EXISTS trg_remittance_operations_limpia_servicio_declarado ON public.remittance_operations;
CREATE TRIGGER trg_remittance_operations_limpia_servicio_declarado
  AFTER UPDATE OF status ON public.remittance_operations
  FOR EACH ROW EXECUTE FUNCTION public.cerebro_limpiar_servicio_declarado();

CREATE OR REPLACE FUNCTION public.cerebro_resolver_servicio(
  p_conv uuid,
  p_declarado text DEFAULT NULL,
  p_intencion text DEFAULT NULL,
  p_monto numeric DEFAULT NULL,
  p_ahora timestamptz DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- services a declaration can name as a target (remesa is the default rail, never a target)
  c_destinos constant text[] := ARRAY['cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd', 'recarga', 'saldo', 'combo', 'visa'];
  c_rieles   constant text[] := ARRAY['cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd'];
  v_hoy      date;
  v_min_cup numeric; v_min_usd numeric; v_min_rec numeric; v_min_efe numeric; v_saldo numeric;
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
BEGIN
  -- Initialised here, not in DECLARE: an error in a declaration is not caught by the EXCEPTION clause below.
  v_hoy := (p_ahora AT TIME ZONE 'America/Guyana')::date;
  v_min_cup := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_min_usd := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                        NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000);
  v_min_rec := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200);
  v_min_efe := cerebro_minimo_efectivo_gyd();
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
                    AND nullif(b.phone, '') IS NOT NULL) AS b_cel
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
      'vacia', NOT (r.recibo OR r.dep) AND coalesce(r.quoted_source_amount, 0) = 0
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
                   WHEN 'zelle' THEN v_min_usd WHEN 'clasica' THEN v_min_usd WHEN 'tropical' THEN v_min_usd
                   WHEN 'efectivo_usd' THEN v_min_efe
                   WHEN 'recarga' THEN coalesce(v_pv, v_pp, v_min_rec)
                   WHEN 'saldo' THEN v_saldo WHEN 'visa' THEN 5000 WHEN 'combo' THEN 25000
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
                   WHEN 'zelle' THEN v_min_usd WHEN 'clasica' THEN v_min_usd WHEN 'tropical' THEN v_min_usd
                   WHEN 'efectivo_usd' THEN v_min_efe
                   WHEN 'recarga' THEN coalesce(v_pv, v_pp, v_min_rec)
                   WHEN 'saldo' THEN v_saldo WHEN 'visa' THEN 5000 WHEN 'combo' THEN 25000
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
      IF v_d >= v_min_y THEN
        v_accion := 'convertir'; v_motivo := 'declarado'; v_dest := v_subj; v_conv_a := v_y; v_servicio := v_y;
        v_cancelar := coalesce(ARRAY(SELECT (e ->> 'id')::uuid FROM jsonb_array_elements(v_ops) e
                                      WHERE (e ->> 'vacia')::boolean
                                        AND (e ->> 'id')::uuid IS DISTINCT FROM v_subj
                                        AND e ->> 'servicio' IS DISTINCT FROM v_x), ARRAY[]::uuid[]);
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

  -- Plain-Spanish sentence for the bot (labels only; the numbers come from the rules above).
  v_lbl_y := (SELECT t.l FROM (VALUES ('cuban_card', 'la tarjeta CUP'), ('clasica', 'la tarjeta clásica'),
                                      ('tropical', 'la tarjeta tropical'), ('zelle', 'Zelle'),
                                      ('efectivo_usd', 'efectivo en USD'), ('recarga', 'la recarga'),
                                      ('saldo', 'el saldo móvil'), ('combo', 'el combo'),
                                      ('visa', 'la extensión de visa'), ('remesa', 'la remesa')) AS t(k, l)
               WHERE t.k = coalesce(v_y, v_conv_a));
  v_lbl_x := (SELECT t.l FROM (VALUES ('cuban_card', 'la tarjeta CUP'), ('clasica', 'la tarjeta clásica'),
                                      ('tropical', 'la tarjeta tropical'), ('zelle', 'Zelle'),
                                      ('efectivo_usd', 'efectivo en USD'), ('recarga', 'la recarga'),
                                      ('saldo', 'el saldo móvil'), ('combo', 'el combo'),
                                      ('visa', 'la extensión de visa'), ('remesa', 'la remesa')) AS t(k, l)
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
           ELSE NULL
         END
  END;
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
      'intencion', CASE WHEN v_y IS NOT NULL THEN v_int END));
EXCEPTION WHEN OTHERS THEN
  -- Fail open: the bot keeps working without the resolver's answer.
  RETURN jsonb_build_object(
    'version', 2, 'servicio', NULL, 'en_curso', NULL, 'accion', 'ninguna', 'permitido', false, 'motivo', 'error',
    'mensaje', NULL, 'minimo_gyd', NULL, 'faltante_gyd', NULL, 'destino_operacion', NULL, 'convertir_a', NULL,
    'cancelar', '[]'::jsonb, 'grupo_mixto', NULL, 'adicionales', '[]'::jsonb, 'operaciones', '[]'::jsonb,
    'evidencia', '{}'::jsonb, 'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200));
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_declarar_servicio(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_declarar_servicio(uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamptz) TO authenticated, service_role;
