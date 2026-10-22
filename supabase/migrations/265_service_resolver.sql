-- =====================================================================
-- 265 -- cerebro_resolver_servicio: ONE read-only answer to "which service is this operation" (staging first)
--
-- odd/tasks/service-resolution.md (S2). Incident 2026-10-22 (1232671b): a 6,200 GYD receipt plus a Cuban mobile became a
-- remesa, "es para una recarga" opened a second empty recarga instead of converting, and the Decisor said RECARGA and CUP
-- at once. The service used to be guessed from words in several places (deposit registration, beneficiary auto-save, agent
-- tools, Decisor). This migration adds the single place that decides it. It is PURE: it never writes, so the writers
-- (266+) can ask it and then act; nothing in the bot calls it yet.
--
--   cerebro_resolver_servicio(p_conv, p_declarado, p_texto, p_monto, p_ahora) RETURNS jsonb   (STABLE, SECURITY DEFINER)
--     p_declarado  the service the agent declared (recarga/saldo/visa/combo, or a remesa rail); it overrides the words
--     p_texto      the message being processed (added to the customer's texts of the recharge window)
--     p_monto      a deposit that is not registered yet (used only when no operation holds a deposit)
--     p_ahora      promo date reference (Guyana day)
--   Fail open: any error returns {"version":1,"accion":"ninguna","motivo":"error",...}; it must never block the bot.
--
-- Output v1 (keys always present): version, servicio (resolved service: recarga|saldo|visa|combo or the remesa rail, 'remesa'
-- when it has none, NULL when ambiguous), en_curso (service family of the subject operation: remesa|recarga|..., NULL),
-- accion {ninguna, convertir, adicional, preguntar}, confianza {alta, media, baja}, motivo, destino_operacion (the
-- operation to convert), convertir_a (target service/rail of a convertir), pregunta ({opciones:[...]} or NULL), via_actual
-- (rail of a remesa that stays a remesa), servicio_pendiente (rail declared before the operation exists), grupo_mixto,
-- adicionales ([{servicio, monto}] of an addition), cancelar (ids of empty duplicates) + cancelar_motivo, alerta (NULL in
-- v1: owner answers Q5/Q6 removed every reason to alert), operaciones[] and evidencia{} (negation-aware words, amount vs
-- price, phone-only recipient, card, Zelle, promo, history of the number).
--
-- Terms. SUBJECT = the open operation the decision is about: the only open operation holding a deposit (receipt row or
-- depositos_mmg row), else the only open operation. DEPOSIT D = the subject's deposit, else p_monto. OPEN = not completed /
-- cancelled. Phone-only recipient = a Cuban mobile (typed, partial or on a recipient row) and no card, Zelle or cash data.
--
-- OWNER RULE (2026-10-22, binding): the customer can ALWAYS change the service of the operation holding the deposit, in any
-- direction (recarga -> CUP card, remesa -> recarga, -> zelle, -> saldo, ...), as long as the deposit meets the minimum of
-- the NEW service. Correction vs addition is decided ONLY by coverage (Q4/Q5): the deposit pays old + new -> adicional;
-- it pays only one -> convertir to the newly named service even if the holder has its own data; it does not meet the new
-- minimum -> ninguna deposito_bajo_minimo with minimo_gyd / faltante_gyd / servicio_minimo so the bot can explain.
--
-- RECENCY (the LATEST signal wins; 89f6df7e, 2026-10-04: a recharge-promo question, 24 min later a Zelle with its account,
-- must stay a Zelle). Signals are read in time order over the customer's texts since the subject operation was created
-- (the last 24 h / last closed operation when there is none) plus p_texto (latest) and the agent's declaration (latest):
--   - a sentence ending in '?' that only asks about price / promo / availability (tienen, hay, cuánto, cuesta, precio,
--     vale, promo, oferta, disponible, cómo funciona, hasta cuándo) is removed first: it is not a request. Negation is the
--     shared cerebro_texto_pide_* / cerebro_quitar_menciones_negadas rule;
--   - destination data of a rail (Zelle word or account, card number or word, cash data, the partial recipient's update
--     time, the recipient rows) is a dated signal too;
--   - a service named EARLIER than a later word of another service or a later rail signal is SUPERSEDED and is no target;
--     equal times (one burst) stay alive, so "13,000 a esta tarjeta y una recarga" asks for both. An addition therefore
--     needs both services alive after the last superseding signal; an older mention alone never creates one.
-- A recarga conversion needs deposit >= the promo recarga price (one fixed price); saldo only its package minimum.
--
-- DECISION TABLE (first match wins; the number is quoted in the comments of the body):
--   R1  group            an open operation is in a mixed group (255)            -> ninguna  grupo_mixto
--   R2  deposits         several open operations each hold their own deposit    -> ninguna  depositos_separados   (Q5: one
--                        deposit per operation is never a mixed send; no alert)
--                        several open operations and none holds a deposit       -> ninguna  varias_operaciones
--   R3  protected        subject human-locked (service/rail/quote)              -> ninguna  bloqueada
--                        subject transferring or incident                       -> ninguna  estado_no_permite
--                        (ready_to_transfer, i.e. a verified deposit, IS convertible: Q6, silently, no alert)
--   R4  declared rail    rail declared on a remesa / no operation               -> ninguna  declarado_riel
--   R5  targets          services named by words or declaration (negation-aware; Q7: recarga, saldo, visa, combo; amount is
--                        evidence ONLY for recarga). For a non-remesa subject the subject's own service is dropped and a
--                        rail is added when declared, named (zelle / tarjeta) or implied by card/Zelle/cash DATA
--                        (Q1 safety net). Subject's service named AND data of another rail -> preguntar datos_de_otro_servicio
--   R6  two targets                                                             -> preguntar palabras_ambiguas
--   R7  one target Y (subject exists):
--       7a recarga without a live or announced promo (207/211)                  -> ninguna  recarga_sin_promo
--       7b deposit < minimum of Y                                               -> ninguna  deposito_bajo_minimo (+ numbers)
--       7c deposit >= old service + Y (old service has data of its own)         -> adicional deposito_cubre_ambos
--       7d otherwise                                                            -> convertir palabras | declarado |
--          datos_de_otro_servicio; empty operations of another service go to cancelar (Q3, duplicado_vacio)
--       7e no subject: servicio Y for the new operation (accion ninguna); with card/Zelle/cash data the deposit stays a
--          remesa unless it pays both (adicional) -> deposito_no_cubre_<Y> | sin_deposito | tarjeta_con_palabras_servicio
--   R8  no words, remesa subject (or none), phone-only recipient, deposit = a whole multiple of the live/announced promo
--       recarga price (Q1)                                                      -> convertir recarga monto_precio_y_celular
--       (no subject: servicio recarga for the new operation, accion ninguna). cancelar as in 7d.
--   R9  default                                                                 -> ninguna  sin_cambio
-- Q2 dropped (no history switch): the number used in an earlier recarga is evidence only.
--
-- Guarded by supabase/staging/assertions/resolver-servicio.sql. ROLLBACK: ROLLBACK-265-service-resolver.sql
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cerebro_resolver_servicio(
  p_conv uuid,
  p_declarado text DEFAULT NULL,
  p_texto text DEFAULT NULL,
  p_monto numeric DEFAULT NULL,
  p_ahora timestamptz DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_celular constant text := '(?<![0-9])(?:\+?53[ -]?)?([56][0-9]{3})[ .-]?([0-9]{4})(?![0-9])';
  c_tarjeta constant text := '(?<![0-9])[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}(?![0-9])';
  c_saldo   constant text := '(recarga\s+de\s+saldo|\msaldo\s+(m[oóOÓ]vil|del?\s+(celular|tel[eé]fono|m[oóOÓ]vil|cuba)|para\s+(el\s+|mi\s+|un\s+|su\s+)?(celular|m[oóOÓ]vil|tel[eé]fono|n[uúUÚ]mero))|\mpaquetes?\s+de\s+saldo)';
  c_visa    constant text := '(extensi[oóOÓ]n\s+de\s+(la\s+|mi\s+)?visa|\mextender\s+(la\s+|mi\s+)?visa|\mvisa\s+(vencida|se\s+me\s+vence|se\s+vence|por\s+vencer)|\minmigraci[oóOÓ]n|extension_de_visa)';
  v_hoy     date;
  v_min_cup numeric; v_min_usd numeric; v_min_rec numeric;
  v_desde   timestamptz;
  v_decl    text := CASE lower(btrim(coalesce(p_declarado, '')))
                      WHEN 'cup' THEN 'cuban_card' WHEN 'efectivo' THEN 'efectivo_usd'
                      ELSE lower(btrim(coalesce(p_declarado, ''))) END;
  c_preg    constant text := '[^.,;:!?\n]*\m(tienen|tiene|hay|cu[aáAÁ]nto|cu[aáAÁ]nta|cuesta|precio|vale|promo\w*|oferta\w*|disponible|c[oóOÓ]mo\s+funciona|hasta\s+cu[aáAÁ]ndo)\M[^.,;:!?\n]*\?';
  v_all     text;
  v_alls    text[] := ARRAY[]::text[];
  sg        record;
  v_txt     text;
  v_start   timestamptz;
  v_dt      timestamptz;
  -- Signals in time order (the LATEST wins): last time each service word / rail signal appeared. infinity = the message
  -- being processed or the agent's declaration.
  t_sal timestamptz; t_rec timestamptz; t_com timestamptz; t_vis timestamptz;
  t_zel timestamptz; t_car timestamptz; t_efe timestamptz; t_zelw timestamptz; t_carw timestamptz;
  v_ts_max timestamptz; v_t_rl timestamptz; v_t_own timestamptz;
  -- raw words (any occurrence, negation- and question-aware), and the ones still alive (not superseded)
  w_rec boolean; w_sal boolean; w_vis boolean; w_com boolean;
  v_targets text[] := ARRAY[]::text[];
  v_y       text; v_yr text; v_y_rail boolean; v_net boolean := false; v_tgt text[];
  v_new_min numeric; v_new_cov numeric; v_old_min numeric; v_old_present boolean;
  v_minimo numeric; v_falta numeric; v_serv_min text; v_min_efe numeric;
  -- operations
  r         record;
  v_ops     jsonb := '[]'::jsonb;
  v_n_open  integer := 0;
  v_n_dep   integer := 0;
  v_grupo   uuid;
  v_holder  uuid;
  v_lone    uuid;
  v_subj    uuid;
  v_s       jsonb;
  v_s_type  text; v_s_rail text; v_s_status text; v_s_dep numeric := 0; v_s_bloq text; v_s_nums integer := 0;
  v_vacias  uuid[] := ARRAY[]::uuid[];
  -- evidence
  v_parcial record;
  v_card boolean := false; v_zelle boolean := false; v_zelle_d boolean := false; v_efec boolean := false; v_propios boolean;
  v_cel boolean; v_solo_cel boolean; v_usado boolean;
  v_pv numeric; v_pp numeric; v_promo boolean; v_precio numeric; v_rail text; v_rail_min numeric;
  v_d numeric := 0; v_fuente text;
  v_es_precio boolean := false;
  -- result
  v_accion text := 'ninguna'; v_motivo text := 'sin_cambio'; v_conf text := 'alta';
  v_servicio text; v_en_curso text; v_dest uuid; v_conv_a text; v_preg jsonb;
  v_adic jsonb := '[]'::jsonb; v_cancelar uuid[] := ARRAY[]::uuid[];
BEGIN
  -- Initialised here, not in DECLARE: an error in a declaration is not caught by the EXCEPTION clause below.
  v_hoy := (p_ahora AT TIME ZONE 'America/Guyana')::date;
  v_min_cup := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_min_usd := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                        NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000);
  v_min_rec := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200);
  v_min_efe := cerebro_minimo_efectivo_gyd();
  v_desde := cerebro_textos_cliente_desde(p_conv);

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
                    AND nullif(b.phone, '') IS NOT NULL) AS b_cel,
           (SELECT max(b.created_at) FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
               AND (nullif(b.card_number, '') IS NOT NULL OR b.beneficiary_type IN ('clasica', 'tropical', 'multiple_distribution'))) AS tt_tarjeta,
           (SELECT max(b.created_at) FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
               AND (nullif(b.zelle_account, '') IS NOT NULL OR b.beneficiary_type = 'zelle')) AS tt_zelle,
           (SELECT max(b.created_at) FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
               AND b.beneficiary_type = 'efectivo_usd') AS tt_efec,
           (SELECT count(*) FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
               AND b.beneficiary_type = 'recarga')::int AS numeros
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at, o.id
  LOOP
    v_n_open := v_n_open + 1;
    v_ops := v_ops || jsonb_build_object(
      'id', r.id, 'servicio', CASE WHEN r.service_type = 'remesa' THEN coalesce(r.riel, 'remesa') ELSE r.service_type END,
      'tipo', r.service_type, 'status', r.status, 'rail', r.riel,
      'deposito', CASE WHEN r.recibo OR r.dep THEN coalesce(r.quoted_source_amount, 0) ELSE 0 END,
      'tiene_deposito', r.recibo OR r.dep,
      'vacia', NOT (r.recibo OR r.dep) AND coalesce(r.quoted_source_amount, 0) = 0,
      'grupo', r.mixed_group_id, 'bloqueo_humano', r.bloqueo,
      'tarjeta', r.b_tarjeta, 'zelle', r.b_zelle, 'efectivo', r.b_efec, 'celular', r.b_cel, 'numeros', r.numeros,
      'creado', r.created_at, 'tt_tarjeta', r.tt_tarjeta, 'tt_zelle', r.tt_zelle, 'tt_efec', r.tt_efec);
    IF r.mixed_group_id IS NOT NULL THEN v_grupo := coalesce(v_grupo, r.mixed_group_id); END IF;
    IF r.recibo OR r.dep THEN
      v_n_dep := v_n_dep + 1; v_holder := coalesce(v_holder, r.id);
    ELSIF coalesce(r.quoted_source_amount, 0) = 0 AND r.bloqueo IS NULL
          AND r.status IN ('collecting_information', 'awaiting_deposit') THEN
      v_vacias := v_vacias || r.id;      -- candidate Q3 duplicate (service filtered once the subject is known)
    END IF;
    v_lone := r.id;
  END LOOP;

  v_subj := CASE WHEN v_n_dep = 1 THEN v_holder WHEN v_n_dep = 0 AND v_n_open = 1 THEN v_lone END;
  IF v_subj IS NOT NULL THEN
    SELECT e INTO v_s FROM jsonb_array_elements(v_ops) e WHERE e ->> 'id' = v_subj::text;
    v_s_type := v_s ->> 'tipo'; v_s_rail := v_s ->> 'rail'; v_s_status := v_s ->> 'status';
    v_s_dep := (v_s ->> 'deposito')::numeric; v_s_bloq := v_s ->> 'bloqueo_humano'; v_s_nums := (v_s ->> 'numeros')::int;
    v_vacias := ARRAY(SELECT x FROM unnest(v_vacias) x
                       WHERE x <> v_subj AND (SELECT e ->> 'tipo' FROM jsonb_array_elements(v_ops) e WHERE e ->> 'id' = x::text) <> v_s_type);
  ELSE
    v_vacias := ARRAY[]::uuid[];
  END IF;

  -- ---- customer signals, in order -------------------------------------------------------------------------------
  -- Window: the customer's texts since the subject operation was created (or the last 24 h / last closed operation when
  -- there is none) plus the message being processed. A sentence that only ASKS about price / promo / availability
  -- ("¿tienen promo de recarga?", "¿cuánto es la recarga?") is removed first: it is not a request.
  v_start := CASE WHEN v_subj IS NOT NULL THEN greatest(v_desde, (v_s ->> 'creado')::timestamptz) ELSE v_desde END;
  SELECT * INTO v_parcial FROM cerebro_beneficiario_parcial bp WHERE bp.conversation_id = p_conv;
  FOR sg IN
    SELECT x.ts, x.t FROM (
      SELECT mm.created_at AS ts, mm.content_text AS t FROM messages mm
       WHERE mm.conversation_id = p_conv AND mm.sender_type = 'customer' AND mm.created_at > v_start AND mm.content_text IS NOT NULL
      UNION ALL
      SELECT 'infinity'::timestamptz, p_texto WHERE nullif(btrim(coalesce(p_texto, '')), '') IS NOT NULL) x
     ORDER BY x.ts
  LOOP
    v_txt := regexp_replace(sg.t, c_preg, ' ', 'gi');
    v_alls := v_alls || v_txt;
    -- "recarga de saldo" is a saldo message, not a recarga one; the shared negation-aware rules do the rest.
    IF coalesce(cerebro_quitar_menciones_negadas(v_txt, 'saldos?') ~* c_saldo, false) THEN t_sal := sg.ts;
    ELSIF cerebro_texto_pide_recarga(v_txt) THEN t_rec := sg.ts; END IF;
    IF cerebro_texto_pide_combo(v_txt) THEN t_com := sg.ts; END IF;
    IF coalesce(v_txt ~* c_visa, false) THEN t_vis := sg.ts; END IF;
    IF coalesce(cerebro_quitar_menciones_negadas(v_txt, 'zelle') ~* 'zelle', false) THEN t_zel := sg.ts; t_zelw := sg.ts; END IF;
    IF coalesce(cerebro_quitar_menciones_negadas(v_txt, 'tarjetas?') ~* '\mtarjeta', false) THEN t_car := sg.ts; t_carw := sg.ts; END IF;
    IF coalesce(v_txt ~ c_tarjeta, false) THEN t_car := sg.ts; END IF;
  END LOOP;
  v_all := array_to_string(v_alls, ' ');
  w_sal := t_sal IS NOT NULL; w_rec := t_rec IS NOT NULL; w_com := t_com IS NOT NULL; w_vis := t_vis IS NOT NULL;

  -- Destination DATA is also a signal, dated: the partial recipient (its update time), the subject's recipient rows
  -- and its chosen rail (since the subject was created). Data older than the window counts as at the window start.
  IF coalesce(nullif(v_parcial.zelle_cuenta, ''), nullif(v_parcial.zelle_nombre, ''), nullif(v_parcial.zelle_nombre_cuenta, '')) IS NOT NULL THEN
    t_zel := greatest(t_zel, v_parcial.actualizado, v_start); END IF;
  IF coalesce((v_s ->> 'zelle')::boolean, false) THEN t_zel := greatest(t_zel, (v_s ->> 'tt_zelle')::timestamptz, v_start); END IF;
  IF v_s_rail = 'zelle' THEN t_zel := greatest(t_zel, v_start); END IF;
  IF coalesce(nullif(v_parcial.tarjeta, ''), '') <> '' THEN t_car := greatest(t_car, v_parcial.actualizado, v_start); END IF;
  IF coalesce((v_s ->> 'tarjeta')::boolean, false) THEN t_car := greatest(t_car, (v_s ->> 'tt_tarjeta')::timestamptz, v_start); END IF;
  IF v_s_rail IN ('clasica', 'tropical') THEN t_car := greatest(t_car, v_start); END IF;
  IF coalesce((v_s ->> 'efectivo')::boolean, false) THEN t_efe := greatest(t_efe, (v_s ->> 'tt_efec')::timestamptz, v_start); END IF;
  IF v_s_rail = 'efectivo_usd' THEN t_efe := greatest(t_efe, v_start); END IF;

  -- The agent's declaration is the latest signal and replaces the service words.
  IF v_decl IN ('recarga', 'saldo', 'visa', 'combo') THEN
    t_sal := NULL; t_rec := NULL; t_com := NULL; t_vis := NULL;
    IF v_decl = 'saldo' THEN t_sal := 'infinity'; ELSIF v_decl = 'recarga' THEN t_rec := 'infinity';
    ELSIF v_decl = 'combo' THEN t_com := 'infinity'; ELSE t_vis := 'infinity'; END IF;
  ELSIF v_decl = 'zelle' THEN t_zel := 'infinity'; t_zelw := 'infinity';
  ELSIF v_decl IN ('cuban_card', 'clasica', 'tropical') THEN t_car := 'infinity'; t_carw := 'infinity';
  ELSIF v_decl = 'efectivo_usd' THEN t_efe := 'infinity';
  END IF;

  -- ALIVE services: the latest signal wins. A service named earlier than a later word of another service or later than
  -- destination data of a rail is SUPERSEDED (the 2026-10-04 bug: a recharge promo question, then a Zelle account).
  -- Ties (same burst) stay alive: "13,000 a esta tarjeta y una recarga" asks for both.
  v_ts_max := greatest(t_sal, t_rec, t_com, t_vis);
  v_t_rl := greatest(t_zel, t_car, t_efe);
  IF t_sal IS NOT NULL AND t_sal >= v_ts_max AND (v_t_rl IS NULL OR t_sal >= v_t_rl) THEN v_targets := v_targets || 'saldo'::text; END IF;
  IF t_rec IS NOT NULL AND t_rec >= v_ts_max AND (v_t_rl IS NULL OR t_rec >= v_t_rl) THEN v_targets := v_targets || 'recarga'::text; END IF;
  IF t_com IS NOT NULL AND t_com >= v_ts_max AND (v_t_rl IS NULL OR t_com >= v_t_rl) THEN v_targets := v_targets || 'combo'::text; END IF;
  IF t_vis IS NOT NULL AND t_vis >= v_ts_max AND (v_t_rl IS NULL OR t_vis >= v_t_rl) THEN v_targets := v_targets || 'visa'::text; END IF;

  -- ---- evidence ----------------------------------------------------------------------------------------------------
  v_card  := coalesce(nullif(v_parcial.tarjeta, ''), '') <> '' OR coalesce(v_all ~ c_tarjeta, false)
             OR coalesce((v_s ->> 'tarjeta')::boolean, false) OR coalesce(v_s_rail IN ('clasica', 'tropical'), false);
  v_zelle_d := coalesce(coalesce(nullif(v_parcial.zelle_cuenta, ''), nullif(v_parcial.zelle_nombre, ''), nullif(v_parcial.zelle_nombre_cuenta, '')) IS NOT NULL, false)
               OR coalesce((v_s ->> 'zelle')::boolean, false) OR coalesce(v_s_rail = 'zelle', false);
  v_zelle := coalesce(v_all ~* 'zelle', false) OR v_zelle_d;
  v_efec  := coalesce((v_s ->> 'efectivo')::boolean, false) OR coalesce(v_s_rail = 'efectivo_usd', false);
  v_propios := v_card OR v_zelle OR v_efec;
  v_cel := coalesce(nullif(v_parcial.celular, ''), '') <> '' OR coalesce(v_all ~ c_celular, false)
           OR coalesce((v_s ->> 'celular')::boolean, false);
  v_solo_cel := v_cel AND NOT v_propios;
  v_usado := EXISTS (SELECT 1 FROM remittance_beneficiaries b
                       JOIN remittance_operations o2 ON o2.id = b.operation_id
                       JOIN conversations cv ON cv.id = p_conv AND cv.contact_id = o2.contact_id
                      WHERE b.beneficiary_type = 'recarga' AND b.phone IS NOT NULL AND o2.id IS DISTINCT FROM v_subj
                        AND b.phone IN (SELECT (m)[1] || (m)[2] FROM regexp_matches(coalesce(v_all, ''), c_celular, 'g') AS m));

  SELECT v.precio_gyd INTO v_pv FROM cerebro_promo_vigente(v_hoy) v;
  SELECT p.precio_gyd INTO v_pp FROM cerebro_promo_proxima(v_hoy) p;
  v_promo := v_pv IS NOT NULL OR v_pp IS NOT NULL;

  IF v_s_dep > 0 THEN v_d := v_s_dep; v_fuente := 'operacion';
  ELSIF coalesce(p_monto, 0) > 0 THEN v_d := p_monto; v_fuente := 'parametro'; END IF;
  v_es_precio := v_d > 0 AND coalesce(v_pv, v_pp) IS NOT NULL AND mod(v_d, coalesce(v_pv, v_pp)) = 0;

  -- The rail the remesa runs (or would run) on: the minimum a card/Zelle/cash deposit has to meet.
  v_rail := CASE WHEN v_s_type = 'remesa' AND v_s_rail IS NOT NULL AND v_s_rail NOT IN ('recarga', 'combo', 'visa', 'saldo') THEN v_s_rail
                 WHEN v_zelle THEN 'zelle' WHEN v_efec THEN 'efectivo_usd' ELSE 'cuban_card' END;
  v_rail_min := CASE WHEN v_rail IN ('zelle', 'clasica', 'tropical') THEN v_min_usd
                     WHEN v_rail = 'efectivo_usd' THEN cerebro_minimo_efectivo_gyd()
                     ELSE v_min_cup END;

  -- Defaults describing the subject.
  v_en_curso := v_s_type;
  v_servicio := CASE WHEN v_subj IS NULL THEN CASE WHEN v_n_open > 1 THEN NULL
                                                   ELSE coalesce(CASE WHEN t_zel IS NOT NULL THEN 'zelle' WHEN t_car IS NOT NULL THEN 'cuban_card' END, 'remesa') END
                     WHEN v_s_type = 'remesa' THEN coalesce(v_s_rail, 'remesa') ELSE v_s_type END;

  <<flow>>
  BEGIN
    -- R1 a mixed group changes only through repartir_envio (255).
    IF v_grupo IS NOT NULL THEN v_motivo := 'grupo_mixto'; EXIT flow; END IF;

    -- R2 Q5: one deposit per operation is NOT a mixed send; nothing is merged or alerted.
    IF v_n_dep > 1 THEN v_motivo := 'depositos_separados'; v_servicio := NULL; v_en_curso := NULL; EXIT flow; END IF;
    IF v_subj IS NULL AND v_n_open > 1 THEN v_motivo := 'varias_operaciones'; v_servicio := NULL; v_en_curso := NULL; EXIT flow; END IF;

    -- R3 a person fixed it / the money is moving: leave it alone. Q6: ready_to_transfer (verified) stays convertible.
    IF v_subj IS NOT NULL THEN
      IF v_s_bloq IS NOT NULL THEN v_motivo := 'bloqueada'; EXIT flow; END IF;
      IF v_s_status IN ('transferring', 'incident') THEN v_motivo := 'estado_no_permite'; EXIT flow; END IF;
    END IF;

    -- R4 a remesa rail declared on a remesa (or no operation) is the rail tools' business (cambiar_servicio).
    IF v_decl IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd') AND (v_s_type IS NULL OR v_s_type = 'remesa') THEN
      v_motivo := 'declarado_riel'; v_servicio := v_decl; EXIT flow;
    END IF;

    -- R5 targets. The customer can always change the service of the operation holding the deposit. For a non-remesa
    -- subject a RAIL can be the new service: declared, named in a (negation-aware) word, or implied by card/Zelle/cash
    -- DATA when the customer did not name the subject's own service (Q1 safety net).
    v_tgt := v_targets;
    IF v_s_type IS NOT NULL AND v_s_type <> 'remesa' THEN
      v_tgt := array_remove(v_targets, v_s_type);
      v_t_own := CASE v_s_type WHEN 'recarga' THEN t_rec WHEN 'saldo' THEN t_sal WHEN 'combo' THEN t_com ELSE t_vis END;
      -- A rail signal LATER than the last mention of the subject's own service supersedes it (latest wins).
      IF v_t_rl IS NOT NULL AND (v_t_own IS NULL OR v_t_rl >= v_t_own) THEN
        IF v_t_own IS NOT NULL AND v_t_rl = v_t_own THEN
          -- same burst: the customer names the subject's service and gives data of another rail: ask once
          v_accion := 'preguntar'; v_motivo := 'datos_de_otro_servicio'; v_conf := 'baja';
          v_preg := jsonb_build_object('opciones', jsonb_build_array(v_s_type,
                      CASE WHEN t_zel = v_t_rl THEN 'zelle' WHEN t_car = v_t_rl THEN 'cuban_card' ELSE 'efectivo_usd' END));
          EXIT flow;
        END IF;
        v_yr := CASE WHEN v_decl IN ('clasica', 'tropical') THEN v_decl
                     WHEN t_zel = v_t_rl THEN 'zelle' WHEN t_car = v_t_rl THEN 'cuban_card' ELSE 'efectivo_usd' END;
        v_net := NOT coalesce(v_decl = v_yr 
                      OR (v_yr = 'zelle' AND t_zelw = v_t_rl) OR (v_yr = 'cuban_card' AND t_carw = v_t_rl), false);
        v_tgt := v_tgt || v_yr;
      END IF;
    END IF;

    -- R6 two services named: ask once.
    IF cardinality(v_tgt) > 1 THEN
      v_accion := 'preguntar'; v_motivo := 'palabras_ambiguas'; v_conf := 'baja';
      v_preg := jsonb_build_object('opciones', to_jsonb(v_tgt));
      EXIT flow;
    END IF;

    -- R7 exactly one new service Y (Q7: words convert recarga, saldo, visa, combo; plus the rails above).
    IF cardinality(v_tgt) = 1 THEN
      v_y := v_tgt[1];
      v_y_rail := v_y IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd');
      -- 7a a recarga needs a live or announced promo (207/211)
      IF v_y = 'recarga' AND NOT v_promo THEN v_motivo := 'recarga_sin_promo'; EXIT flow; END IF;
      v_new_min := CASE WHEN v_y_rail THEN CASE WHEN v_y IN ('zelle', 'clasica', 'tropical') THEN v_min_usd
                                                WHEN v_y = 'efectivo_usd' THEN v_min_efe ELSE v_min_cup END
                        WHEN v_y = 'recarga' THEN coalesce(v_pv, v_pp, v_min_rec) WHEN v_y = 'saldo' THEN cerebro_saldo_precio()
                        WHEN v_y = 'visa' THEN 5000 ELSE 25000 END;
      -- what Y costs when the same deposit also has to pay the old service (a recarga is priced by the promo)
      v_new_cov := CASE WHEN v_y = 'recarga' THEN coalesce(v_pv, v_pp, v_min_rec) ELSE v_new_min END;
      IF v_subj IS NOT NULL THEN
        -- The old service, as the deposit would have to pay it if it stayed.
        v_old_min := CASE v_s_type
                       WHEN 'remesa' THEN CASE WHEN v_rail IN ('zelle', 'clasica', 'tropical') THEN v_min_usd
                                               WHEN v_rail = 'efectivo_usd' THEN v_min_efe ELSE v_min_cup END
                       WHEN 'recarga' THEN coalesce(v_pv, v_pp, v_min_rec) WHEN 'saldo' THEN cerebro_saldo_precio()
                       WHEN 'visa' THEN 5000 ELSE 25000 END;
        -- A phone-only remesa or a recarga without numbers has nothing of its own to pay: the change is a correction.
        v_old_present := CASE v_s_type WHEN 'remesa' THEN v_propios WHEN 'recarga' THEN v_s_nums > 0
                                       WHEN 'saldo' THEN v_s_nums > 0 ELSE true END;
        -- 7b (c) the deposit does not meet the minimum of the NEW service: no change; the bot explains with these numbers.
        IF v_d > 0 AND v_d < v_new_min THEN
          v_motivo := 'deposito_bajo_minimo'; v_minimo := v_new_min; v_falta := v_new_min - v_d; v_serv_min := v_y; EXIT flow;
        END IF;
        IF v_d > 0 AND v_old_present AND v_d >= v_old_min + v_new_cov THEN
          -- 7c (a) one deposit pays both: a mixed send (Q4/Q5)
          v_accion := 'adicional'; v_motivo := 'deposito_cubre_ambos'; v_servicio := v_y;
          v_adic := jsonb_build_array(jsonb_build_object('servicio', v_y, 'monto', v_new_cov));
          v_dest := (SELECT (e ->> 'id')::uuid FROM jsonb_array_elements(v_ops) e
                      WHERE (e ->> 'id')::uuid = ANY (v_vacias) AND e ->> 'servicio' = v_y LIMIT 1);
        ELSE
          -- 7d (b) it pays only one: the customer's newest choice wins, even if the holder has its own data
          v_accion := 'convertir'; v_dest := v_subj; v_conv_a := v_y; v_servicio := v_y; v_cancelar := v_vacias;
          v_motivo := CASE WHEN v_net THEN 'datos_de_otro_servicio' WHEN v_decl = v_y THEN 'declarado' ELSE 'palabras' END;
        END IF;
        EXIT flow;
      END IF;
      -- 7e no operation yet: the new operation will be Y (a deposit that has card/Zelle/cash data stays a remesa unless it pays both: 211)
      IF v_d > 0 AND v_d < v_new_min THEN
        v_motivo := 'deposito_bajo_minimo'; v_minimo := v_new_min; v_falta := v_new_min - v_d; v_serv_min := v_y; EXIT flow;
      END IF;
      IF v_propios THEN
        IF v_y IN ('visa', 'combo') THEN v_motivo := 'tarjeta_con_palabras_servicio'; EXIT flow; END IF;
        IF v_d <= 0 THEN v_motivo := 'sin_deposito'; EXIT flow; END IF;
        IF v_d >= v_rail_min + v_new_cov THEN
          v_accion := 'adicional'; v_motivo := 'deposito_cubre_ambos'; v_servicio := v_y;
          v_adic := jsonb_build_array(jsonb_build_object('servicio', v_y, 'monto', v_new_cov));
        ELSE
          v_motivo := 'deposito_no_cubre_' || v_y; v_servicio := v_rail;
        END IF;
        EXIT flow;
      END IF;
      v_motivo := CASE WHEN v_decl = v_y THEN 'declarado' ELSE 'palabras' END;
      v_servicio := v_y;
      EXIT flow;
    END IF;

    -- R8 no words: the money and the recipient say recarga (Q1). Phone-only + a whole multiple of the promo price.
    IF v_solo_cel AND v_promo AND v_es_precio AND (v_s_type IS NULL OR v_s_type = 'remesa') THEN
      v_motivo := 'monto_precio_y_celular'; v_servicio := 'recarga';
      IF v_subj IS NOT NULL THEN
        v_accion := 'convertir'; v_dest := v_subj; v_conv_a := 'recarga'; v_cancelar := v_vacias;
      END IF;
      EXIT flow;
    END IF;
    -- R9 default: sin_cambio.
  END;

  -- A remesa that stays a remesa reports its rail; anything converted, asked or non-remesa reports none.
  RETURN jsonb_build_object(
    'version', 1,
    'servicio', v_servicio,
    'en_curso', v_en_curso,
    'accion', v_accion,
    'confianza', v_conf,
    'motivo', v_motivo,
    'destino_operacion', v_dest,
    'convertir_a', v_conv_a,
    'pregunta', v_preg,
    'via_actual', CASE WHEN v_en_curso = 'remesa' AND v_accion IN ('ninguna', 'adicional') THEN v_s_rail END,
    'servicio_pendiente', (SELECT p.tipo FROM cerebro_destino_pendiente p
                            WHERE p.conversation_id = p_conv AND p.actualizado > p_ahora - interval '24 hours'),
    'grupo_mixto', v_grupo,
    'adicionales', v_adic,
    'cancelar', to_jsonb(v_cancelar),
    'cancelar_motivo', CASE WHEN cardinality(v_cancelar) > 0 THEN 'duplicado_vacio' END,
    'alerta', NULL,
    'minimo_gyd', v_minimo, 'faltante_gyd', v_falta, 'servicio_minimo', v_serv_min,
    'operaciones', v_ops,
    'evidencia', jsonb_build_object(
      'palabras', jsonb_build_object('recarga', w_rec, 'saldo', w_sal, 'visa', w_vis, 'combo', w_com),
      'activas', to_jsonb(v_targets),
      'declarado', nullif(v_decl, ''),
      'monto', nullif(v_d, 0), 'monto_fuente', v_fuente,
      'monto_es_precio_recarga', v_es_precio,
      'precio_recarga', coalesce(v_pv, v_pp),
      'unidades_recarga', CASE WHEN v_es_precio THEN (v_d / coalesce(v_pv, v_pp))::int END,
      'numero_usado_en_recarga', v_usado,
      'celular', v_cel, 'celular_solo', v_solo_cel,
      'tarjeta', v_card, 'zelle', v_zelle, 'efectivo', v_efec,
      'promo', jsonb_build_object('vigente', v_pv IS NOT NULL, 'proxima', v_pp IS NOT NULL)));
EXCEPTION WHEN OTHERS THEN
  -- Fail open: the bot keeps working as it did before the resolver existed.
  RETURN jsonb_build_object(
    'version', 1, 'servicio', NULL, 'en_curso', NULL, 'accion', 'ninguna', 'confianza', 'baja', 'motivo', 'error',
    'destino_operacion', NULL, 'convertir_a', NULL, 'pregunta', NULL, 'via_actual', NULL, 'servicio_pendiente', NULL,
    'grupo_mixto', NULL, 'adicionales', '[]'::jsonb, 'cancelar', '[]'::jsonb, 'cancelar_motivo', NULL, 'alerta', NULL,
    'minimo_gyd', NULL, 'faltante_gyd', NULL, 'servicio_minimo', NULL,
    'operaciones', '[]'::jsonb, 'evidencia', '{}'::jsonb, 'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200));
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamptz) TO authenticated, service_role;
