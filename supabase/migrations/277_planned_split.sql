-- 277 (a split planned before the deposit; facts instead of a refusal). Gap 3 of the S5b measurement (odd/notes/db-tools-progress.md):
-- repartir_envio answered "No hay un deposito registrado para repartir todavia" before the deposit (M3b), and with a deposit that
-- differs from the parts (the Marlene shape: 150 + 100 USD + 15,000 planned, 71,200 deposited) it refused with two sums.
--   * cerebro_reparto_planeado (conversation_id PK): the plan [{servicio, monto_gyd}] and its total; RLS on, service_role only.
--   * cerebro_repartir_envio(conv, partes, exec) -> text (signature and return type unchanged): with NO deposit it saves the plan and
--     opens one empty operation per part (so each part's data lands on its own operation, 276) and answers "Reparto planeado ...";
--     with a deposit that does not match it keeps the plan and answers "REPARTO NO APLICADO: ..." with the planned parts (GYD and USD),
--     the planned total, the deposit and the difference, nothing changed; a successful split deletes the plan.
--   * cerebro_registrar_deposito: after attaching a deposit (movido / sumado / creado) the plan is applied when the operation's
--     amount is exactly the planned total (cerebro_repartir_envio with the planned parts); a different deposit leaves the plan.
--   * cerebro_resolver_servicio: new key reparto_planeado = {partes:[{servicio, monto_gyd, usd}], total_gyd, deposito_gyd,
--     diferencia_gyd (deposit - plan), coincide} or null: the facts the Decisor needs (servicio_resuelto carries it).
--   * cerebro_limpiar_servicio_declarado also clears the plan when the conversation's last operation closes.
--   * helpers (service_role only): _cerebro_usd_parte, _cerebro_texto_partes, _cerebro_op_parte, _cerebro_reparto_planear,
--     _cerebro_aplicar_plan_reparto.
-- Rollback restores the four previous bodies and drops the helpers and the table (plans are lost).

CREATE TABLE IF NOT EXISTS public.cerebro_reparto_planeado (
  conversation_id uuid PRIMARY KEY REFERENCES public.conversations(id) ON DELETE CASCADE,
  partes          jsonb NOT NULL,
  total_gyd       numeric NOT NULL,
  actor           text,
  creado_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.cerebro_reparto_planeado IS '277: the split of ONE deposit among services that the agent planned (parts [{servicio, monto_gyd}], total). One row per conversation, the latest plan wins; applied when a deposit of exactly total_gyd arrives, deleted after a split or when the last operation closes.';
ALTER TABLE public.cerebro_reparto_planeado ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.cerebro_reparto_planeado FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.cerebro_reparto_planeado TO service_role;

-- GYD -> USD of one part, whole dollars (floor), by the service's own rate; NULL where the service has no USD figure.
CREATE OR REPLACE FUNCTION public._cerebro_usd_parte(p_servicio text, p_gyd numeric)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN p_gyd IS NULL OR p_gyd <= 0 THEN NULL
              WHEN p_servicio = 'zelle' THEN cerebro_zelle_usd_desde_gyd(p_gyd)
              WHEN p_servicio IN ('clasica', 'tropical', 'mexico') THEN floor(p_gyd / NULLIF(crm_tasa_vigente('usd'), 0))
              WHEN p_servicio = 'efectivo_usd' THEN floor(p_gyd / NULLIF(crm_tasa_vigente('efectivo'), 0))
         END;
$function$;

-- "mexico 39,000 GYD (150 USD), efectivo USD 29,000 GYD (100 USD), tarjeta CUP 15,000 GYD" from [{servicio, monto_gyd}].
CREATE OR REPLACE FUNCTION public._cerebro_texto_partes(p_partes jsonb)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(string_agg(
           CASE e ->> 'servicio' WHEN 'cuban_card' THEN 'tarjeta CUP' WHEN 'efectivo_usd' THEN 'efectivo USD' ELSE e ->> 'servicio' END
           || ' ' || _cerebro_fmt_monto((e ->> 'monto_gyd')::numeric) || ' GYD'
           || coalesce(' (' || trim_scale(_cerebro_usd_parte(e ->> 'servicio', (e ->> 'monto_gyd')::numeric))::text || ' USD)', ''),
           ', ' ORDER BY ord), '')
    FROM jsonb_array_elements(p_partes) WITH ORDINALITY t(e, ord);
$function$;

-- The open operation of a service, or a new EMPTY one (collecting_information, 0 GYD, MXN for mexico) with the account/contact of the
-- conversation and the deposit data of the newest open operation. Used for the parts of a split planned before the deposit.
CREATE OR REPLACE FUNCTION public._cerebro_op_parte(p_conv uuid, p_servicio text, p_actor text DEFAULT 'agent:repartir_envio', p_razon text DEFAULT 'planned split part')
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_srv text := lower(btrim(coalesce(p_servicio, '')));
  v_type text; v_dm text; v_op uuid; v_account uuid; v_contact uuid;
BEGIN
  IF p_conv IS NULL OR v_srv NOT IN ('cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd', 'recarga', 'saldo', 'combo', 'visa', 'mexico') THEN
    RETURN NULL;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));
  v_type := CASE WHEN v_srv IN ('recarga', 'combo', 'visa', 'saldo', 'mexico') THEN v_srv ELSE 'remesa' END;
  v_dm   := CASE WHEN v_type = 'remesa' THEN v_srv END;
  SELECT o.id INTO v_op FROM remittance_operations o
   WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
     AND (CASE WHEN v_type = 'remesa' THEN o.service_type = 'remesa' AND cerebro_riel_op(o.id) = v_srv ELSE o.service_type = v_type END)
   ORDER BY o.created_at DESC, o.id LIMIT 1;
  IF v_op IS NOT NULL THEN RETURN v_op; END IF;
  SELECT c.account_id, c.contact_id INTO v_account, v_contact FROM conversations c WHERE c.id = p_conv;
  IF v_account IS NULL THEN RETURN NULL; END IF;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     deposit_method, source_country, source_currency, quoted_source_amount, destination_currency)
  SELECT v_account, p_conv, coalesce(h.contact_id, v_contact), 'collecting_information', v_type, v_dm,
         h.deposit_method, h.source_country, coalesce(h.source_currency, 'GYD'), 0,
         CASE WHEN v_type = 'mexico' THEN 'MXN' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT x.* FROM remittance_operations x
                        WHERE x.conversation_id = p_conv AND x.status NOT IN ('completed', 'cancelled')
                        ORDER BY x.created_at DESC, x.id LIMIT 1) h ON true
  RETURNING id INTO v_op;
  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account, 'remittance_operations', v_op, 'service_type', 'agent_service_change', coalesce(nullif(btrim(p_actor), ''), 'agent:repartir_envio'),
          p_razon || ': ' || v_srv, '{}'::jsonb,
          jsonb_build_object('service', v_srv, 'status', 'collecting_information', 'quoted_source_amount', 0));
  RETURN v_op;
END $function$;

-- Saves the plan (parts as parsed by _cerebro_partes_envio_parse) and, with p_abrir, opens an empty operation per part. Returns
-- {ok, texto}. At least two different services are required.
CREATE OR REPLACE FUNCTION public._cerebro_reparto_planear(p_conv uuid, p_partes jsonb, p_abrir boolean, p_actor text DEFAULT 'agent:repartir_envio')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n int; v_d int; v_total numeric; v_e jsonb;
BEGIN
  SELECT count(*), count(DISTINCT e ->> 'servicio'), sum((e ->> 'monto_gyd')::numeric)
    INTO v_n, v_d, v_total FROM jsonb_array_elements(p_partes) e;
  IF coalesce(v_n, 0) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'texto', 'No se pudo repartir: hacen falta al menos dos servicios (detalle: at least two parts are required). No cambie nada.');
  END IF;
  IF v_d <> v_n THEN
    RETURN jsonb_build_object('ok', false, 'texto', 'No se pudo repartir: hay un servicio repetido. No cambie nada.');
  END IF;
  INSERT INTO cerebro_reparto_planeado (conversation_id, partes, total_gyd, actor, creado_at)
  VALUES (p_conv, p_partes, v_total, p_actor, now())
  ON CONFLICT (conversation_id) DO UPDATE SET partes = EXCLUDED.partes, total_gyd = EXCLUDED.total_gyd, actor = EXCLUDED.actor, creado_at = now();
  IF p_abrir THEN
    FOR v_e IN SELECT e FROM jsonb_array_elements(p_partes) e LOOP
      PERFORM _cerebro_op_parte(p_conv, v_e ->> 'servicio', p_actor, 'planned split part');
    END LOOP;
  END IF;
  RETURN jsonb_build_object('ok', true, 'total', v_total, 'texto',
    'Reparto planeado (todavia sin deposito, nada aplicado): ' || _cerebro_texto_partes(p_partes) || '. Total ' || _cerebro_fmt_monto(v_total)
    || ' GYD. Cada parte tiene ya su operacion vacia donde guardar sus datos; cuando llegue un deposito de exactamente '
    || _cerebro_fmt_monto(v_total) || ' GYD se reparte solo. Si el deposito es otro, repartir_envio dara los hechos para preguntarle al cliente.');
END $function$;

-- Applies the planned split when the deposit just attached to p_op is exactly the planned total. Never raises.
CREATE OR REPLACE FUNCTION public._cerebro_aplicar_plan_reparto(p_conv uuid, p_op uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pl cerebro_reparto_planeado%ROWTYPE; v_tot numeric; v_txt text; v_res text;
BEGIN
  SELECT * INTO v_pl FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT o.quoted_source_amount INTO v_tot FROM remittance_operations o WHERE o.id = p_op;
  IF v_tot IS DISTINCT FROM v_pl.total_gyd THEN RETURN false; END IF;
  SELECT string_agg(CASE e ->> 'servicio' WHEN 'cuban_card' THEN 'cup' WHEN 'efectivo_usd' THEN 'efectivo usd' ELSE e ->> 'servicio' END
                    || ' ' || trim_scale((e ->> 'monto_gyd')::numeric)::text, ', ' ORDER BY ord)
    INTO v_txt FROM jsonb_array_elements(v_pl.partes) WITH ORDINALITY t(e, ord);
  v_res := cerebro_repartir_envio(p_conv, v_txt, 'auto:registrar_deposito');
  RETURN v_res LIKE 'Reparto hecho%';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[wacrm] _cerebro_aplicar_plan_reparto failed for % (%): %', p_conv, SQLSTATE, SQLERRM;
  RETURN false;
END $function$;

REVOKE ALL ON FUNCTION public._cerebro_usd_parte(text, numeric), public._cerebro_texto_partes(jsonb),
  public._cerebro_op_parte(uuid, text, text, text), public._cerebro_reparto_planear(uuid, jsonb, boolean, text),
  public._cerebro_aplicar_plan_reparto(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._cerebro_usd_parte(text, numeric), public._cerebro_texto_partes(jsonb),
  public._cerebro_op_parte(uuid, text, text, text), public._cerebro_reparto_planear(uuid, jsonb, boolean, text),
  public._cerebro_aplicar_plan_reparto(uuid, uuid) TO service_role;

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
    DELETE FROM public.cerebro_reparto_planeado WHERE conversation_id = NEW.conversation_id;
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_repartir_envio(p_conv uuid, p_partes text, p_execution text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_actor       constant text := 'automation:cerebro_repartir_envio';
  v_parse       jsonb;
  v_op          uuid;
  v_res         jsonb;
  v_text        text;
  v_outcome     text;
  v_prev_origin text;
  v_prev_actor  text;
  v_p           jsonb;
  v_o           remittance_operations%ROWTYPE;
  v_lista       text[] := ARRAY[]::text[];
  v_dep         numeric;
  v_saldo       numeric;
  v_motivo      text;
  v_a           text;
  v_b           text;
  v_plan        jsonb;
BEGIN
  v_parse := _cerebro_partes_envio_parse(p_partes);

  IF NOT (v_parse ->> 'ok')::boolean THEN
    v_outcome := 'no_entendido';
    v_text := CASE WHEN v_parse ->> 'segmento' = '' THEN 'No entendi el reparto: no vi ninguna parte.'
                   ELSE 'No entendi esta parte: "' || (v_parse ->> 'segmento') || '".' END
              || ' Indica cada parte con servicio y monto en GYD, por ejemplo: "clasica 18200, recarga 6200".';
  ELSE
    -- One splitter at a time per conversation.
    PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_repartir_envio:' || p_conv::text, 0));

    -- The operation holding the deposit: grouped first, then deposit/receipt holder, newest first; else the newest with an amount.
    SELECT o.id INTO v_op
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv
       AND o.status NOT IN ('completed', 'cancelled')
       AND (o.mixed_group_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL)
            OR EXISTS (SELECT 1 FROM remittance_operation_receipts rr WHERE rr.operation_id = o.id)
            OR coalesce(o.quoted_source_amount, 0) > 0)
     ORDER BY (o.mixed_group_id IS NOT NULL) DESC,
              (EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL)
               OR EXISTS (SELECT 1 FROM remittance_operation_receipts rr WHERE rr.operation_id = o.id)) DESC,
              o.created_at DESC
     LIMIT 1;

    IF v_op IS NULL THEN
      -- (277) No deposit yet: the split is PLANNED (parts persisted, one empty operation per part) and applied when a deposit of
      -- exactly the planned total arrives (cerebro_registrar_deposito).
      v_plan := _cerebro_reparto_planear(p_conv, v_parse -> 'partes', true, 'agent:repartir_envio');
      v_outcome := CASE WHEN (v_plan ->> 'ok')::boolean THEN 'planeado' ELSE 'rechazado' END;
      v_text := v_plan ->> 'texto';
    ELSE
      v_prev_origin := coalesce(current_setting('wacrm.origin', true), '');
      v_prev_actor  := coalesce(current_setting('wacrm.actor', true), '');
      BEGIN
        PERFORM set_config('wacrm.origin', 'admin', true);
        PERFORM set_config('wacrm.actor', c_actor, true);
        v_res := _repartir_envio_core(v_op, v_parse -> 'partes', 'automation_mixed_split', c_actor,
                                      'n8n execution ' || coalesce(nullif(btrim(p_execution), ''), 'unknown'));
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
      EXCEPTION
        WHEN SQLSTATE '22023' THEN
          PERFORM set_config('wacrm.origin', v_prev_origin, true);
          PERFORM set_config('wacrm.actor', v_prev_actor, true);
          v_outcome := 'rechazado';
          IF SQLERRM LIKE 'the parts add up to % but the total to split is %' THEN
            v_a := substring(SQLERRM from 'add up to ([0-9.]+) but');
            v_b := substring(SQLERRM from 'total to split is ([0-9.]+)$');
            -- (277) Facts instead of a bare refusal: the plan is kept and the answer carries what the Decisor needs.
            v_plan := _cerebro_reparto_planear(p_conv, v_parse -> 'partes', false, 'agent:repartir_envio');
            v_text := 'REPARTO NO APLICADO: las partes suman ' || _cerebro_fmt_monto(v_a::numeric) || ' GYD y el deposito a repartir es '
                      || _cerebro_fmt_monto(v_b::numeric) || ' GYD ('
                      || CASE WHEN v_a::numeric > v_b::numeric THEN 'faltan ' || _cerebro_fmt_monto(v_a::numeric - v_b::numeric) || ' GYD para cubrir las partes'
                              ELSE 'sobran ' || _cerebro_fmt_monto(v_b::numeric - v_a::numeric) || ' GYD del deposito' END
                      || '). Partes planeadas: ' || _cerebro_texto_partes(v_parse -> 'partes') || '. No se cambio nada. '
                      || 'Preguntale al cliente que parte cambia (o si deposita el resto) y vuelve a llamar con montos que sumen exactamente '
                      || _cerebro_fmt_monto(v_b::numeric) || ' GYD. No prometas ninguna entrega hasta entonces.';
          ELSE
            v_motivo := CASE
              WHEN SQLERRM LIKE 'at least two parts%' THEN 'hacen falta al menos dos servicios'
              WHEN SQLERRM LIKE 'service % appears more than once' THEN 'hay un servicio repetido'
              WHEN SQLERRM LIKE 'the operation''s own service%' THEN 'el servicio de la operacion actual debe ser una de las partes'
              WHEN SQLERRM = 'operation is closed' THEN 'la operacion ya esta cerrada'
              WHEN SQLERRM LIKE 'there is no money to split%' THEN 'la operacion no tiene un monto registrado'
              WHEN SQLERRM LIKE 'group member % is completed%' THEN 'un servicio del grupo ya esta completado'
              ELSE 'el reparto no es valido' END;
            v_text := 'No se pudo repartir: ' || v_motivo || ' (detalle: ' || SQLERRM || '). No cambie nada.';
          END IF;
        WHEN OTHERS THEN
          PERFORM set_config('wacrm.origin', v_prev_origin, true);
          PERFORM set_config('wacrm.actor', v_prev_actor, true);
          RAISE;
      END;

      IF v_res IS NOT NULL THEN
        v_outcome := 'repartido';
        DELETE FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
        FOR v_p IN SELECT * FROM jsonb_array_elements(v_res -> 'partes') LOOP
          SELECT * INTO v_o FROM remittance_operations WHERE id = (v_p ->> 'operation_id')::uuid;
          v_lista := v_lista || (
            CASE v_p ->> 'servicio' WHEN 'cuban_card' THEN 'tarjeta CUP' WHEN 'efectivo_usd' THEN 'efectivo USD' ELSE v_p ->> 'servicio' END
            || ' ' || _cerebro_fmt_monto((v_p ->> 'monto_gyd')::numeric) || ' GYD'
            || CASE WHEN v_o.quoted_destination_amount IS NOT NULL AND v_o.destination_currency IS NOT NULL
                    THEN ' (' || trim_scale(v_o.quoted_destination_amount)::text || ' ' || v_o.destination_currency || ')' ELSE '' END);
        END LOOP;
        v_dep   := (v_res ->> 'depositado')::numeric;
        v_saldo := (v_res ->> 'saldo')::numeric;
        v_text := 'Reparto hecho: ' || array_to_string(v_lista, ', ') || '. ' ||
          CASE
            WHEN v_dep > 0 AND v_saldo = 0 THEN 'Deposito ' || _cerebro_fmt_monto(v_dep) || ' GYD verificado, todo listo para transferir.'
            WHEN v_dep > 0 AND v_saldo > 0 THEN 'Deposito ' || _cerebro_fmt_monto(v_dep) || ' GYD verificado, faltan ' ||
                                                _cerebro_fmt_monto(v_saldo) || ' GYD por depositar para completar.'
            WHEN v_dep > 0 THEN 'Deposito ' || _cerebro_fmt_monto(v_dep) || ' GYD verificado, sobran ' ||
                                _cerebro_fmt_monto(-v_saldo) || ' GYD frente al reparto; un operador debe revisarlo.'
            ELSE 'Todavia no hay deposito verificado: queda pendiente el comprobante de ' || _cerebro_fmt_monto(v_dep + v_saldo) || ' GYD.'
          END;
      END IF;
    END IF;
  END IF;

  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
  VALUES (coalesce(nullif(btrim(p_execution), ''), gen_random_uuid()::text) || ':repartir_envio:' || md5(coalesce(p_partes, '')),
          'repartir_envio', p_execution, p_conv, v_op, jsonb_build_array(to_jsonb(p_partes)), v_outcome)
  ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN v_text;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito(p_conv uuid, p_monto numeric, p_moneda text, p_stage uuid, p_nota text, p_comp_id text)
 RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_rev     boolean;
  v_recarga boolean := false;
  v_combo   boolean := false;
  v_visa    boolean := false;
  v_mexico  boolean := false;
  v_open_m  boolean := false;
  v_open_r  boolean := false;
  v_open_c  boolean := false;
  v_open_v  boolean := false;
  v_ya      uuid;
  v_ex      uuid;
  v_suma    uuid;
  v_id      uuid;
  v_phone   text;
  v_ref     text;
  v_nota    text;
  v_motivo  text;
  v_contact uuid;
  v_total   numeric;
  v_ventana integer := COALESCE(NULLIF(cerebro_config_get('completar_ventana_horas'), '')::int, 6);
  v_min_cup numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_res     jsonb;
  v_dest    uuid;
  v_accion  text;
BEGIN
  -- (267) One writer at a time per conversation: the same lock cerebro_aplicar_servicio (266) takes (re-entrant).
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));
  v_rev := cerebro_es_revendedor(p_conv);
  -- (202, 209, 213, 267) Which kind of operation this deposit belongs to (at most one flag is true; none = a remesa).
  -- (267) The service comes from facts, never from the customer's words: cerebro_resolver_servicio (265) gives the service
  -- of the operation this deposit joins or creates (the open operation that holds the money, else the declared intent,
  -- else Q1, else remesa). A reseller's deposit is always a remesa. A resolver error keeps the remesa fallback.
  IF NOT v_rev THEN
    v_res    := cerebro_resolver_servicio(p_conv, NULL::text, NULL::text, p_monto);
    v_dest   := nullif(v_res ->> 'destino_operacion', '')::uuid;
    v_accion := v_res ->> 'accion';
    IF COALESCE(v_res ->> 'motivo', '') = 'error' THEN
      NULL;  -- fail open: remesa, all three flags stay false
    ELSIF v_res ->> 'servicio' IS NOT NULL THEN
      v_recarga := (v_res ->> 'servicio') = 'recarga';
      v_combo   := (v_res ->> 'servicio') = 'combo';
      v_visa    := (v_res ->> 'servicio') = 'visa';
      v_mexico  := (v_res ->> 'servicio') = 'mexico';
    ELSE
      -- No service decided (several open operations and no deposit): the open operation keeps winning, in the live order
      -- recarga > combo > visa. No words are read; with nothing open the deposit is a remesa.
      v_open_r := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_c := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_v := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'visa' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_m := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'mexico' AND o.status NOT IN ('completed', 'cancelled'));
      v_recarga := v_open_r;
      v_combo   := v_open_c AND NOT v_open_r;
      v_visa    := v_open_v AND NOT v_open_r AND NOT v_open_c;
      v_mexico  := v_open_m AND NOT v_open_r AND NOT v_open_c AND NOT v_open_v;
    END IF;
  END IF;

  v_nota := COALESCE(p_nota,'');
  IF NULLIF(p_comp_id,'') IS NOT NULL AND v_nota NOT LIKE '%'||p_comp_id||'%' THEN
    v_nota := v_nota || chr(10) || p_comp_id;
  END IF;

  IF NOT cerebro_transid_plausible(NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '')) THEN
    p_stage := 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid;
    v_motivo := 'REFERENCIA IMPOSIBLE: ese numero no puede ser un TransID de MMG. El contador '
      || 'solo crece y este queda por debajo de todos los recibidos, asi que casi seguro '
      || 'lo leyo la vision de una CAPTURA o de una foto de otra pantalla, no de un '
      || 'comprobante directo. NO se ha registrado como deposito normal: mire la imagen y '
      || 'pidale al cliente el comprobante original antes de dar nada por recibido.';
    -- v_nota keeps the caller's note plus the appended reason, byte for byte:
    -- cerebro_parsear_comprobantes still consumes it. The reason column is a
    -- separate variable (never v_nota) so the receipt code never leaks into it.
    v_nota := v_nota || chr(10) || v_motivo;
  END IF;

  -- (160) Idempotency: check remittance_operation_receipts.comp_id instead
  -- of deals.notes LIKE %comp_id%. The substring form is load-bearing:
  -- 156 matched `deals.notes LIKE '%'||p_comp_id||'%'`, and the note
  -- carries the receipt code as 'COMP-'||comp, while the caller passes
  -- the bare comp. An equality test alone therefore never matches on the
  -- real flow and silently returns 'creado', creating a second
  -- operation for a deposit that was already registered.
  IF NULLIF(p_comp_id,'') IS NOT NULL THEN
    SELECT ro.id INTO v_ya
      FROM remittance_operations ro
      JOIN remittance_operation_receipts r ON r.operation_id = ro.id
     WHERE ro.conversation_id = p_conv
       AND (r.comp_id = p_comp_id OR r.comp_id LIKE '%'||p_comp_id||'%')
     LIMIT 1;
    IF v_ya IS NOT NULL THEN
      RETURN QUERY SELECT v_ya, 'ya registrado (idempotente)'::text, v_rev, false; RETURN;
    END IF;
  END IF;

  -- (182 <- 178) The same receipt sent again (another image, another COMP id): its Ref is already
  -- a receipt of an open operation of this chat. It is that deposit, not a new one: never summed,
  -- never a second operation.
  v_ref := NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '');
  IF v_ref IS NOT NULL THEN
    SELECT ro.id INTO v_ya
      FROM remittance_operations ro
      JOIN remittance_operation_receipts r ON r.operation_id = ro.id
     WHERE ro.conversation_id = p_conv
       AND ro.status NOT IN ('completed', 'cancelled')
       AND r.reference ~ ('(^|[^0-9])' || v_ref || '([^0-9]|$)')
     ORDER BY ro.created_at DESC LIMIT 1;
    IF v_ya IS NOT NULL THEN
      RETURN QUERY SELECT v_ya, 'ya registrado (misma referencia)'::text, v_rev, false; RETURN;
    END IF;
  END IF;

  -- (160, 232) movido branch: find the latest open remesa operation for this conversation that has no receipt yet,
  -- and is NOT (has a vigente recipient AND still owes saldo AND already holds money).
  -- 156's guard was `NOT (d.value > 0 AND notes LIKE '%BENEFICIARIO%')`: value is money ALREADY deposited, so a deal with
  -- money and a recipient was a complete remittance and a new deposit was a different one. 160 translated "money
  -- already there" into `saldo > 0` (money still OWED), which for a recipient-first operation (nothing deposited, the
  -- whole quote owed) excluded exactly the operation the deposit belongs to (Edel, 2026-10-08).
  -- (232) The guard now needs the operation to hold money. It holds money when quoted_source_amount > 0, or any receipt
  -- row hangs from it, or something was consumed against it (the `depositado` of cerebro_saldo_operacion). An operation
  -- in incident or with a locked quoted_source_amount keeps the 160 behaviour: the deposit amount would be overwritten
  -- over a decision someone made, or suppressed by the lock.
  IF NOT v_rev THEN
    SELECT ro.id INTO v_ex
      FROM remittance_operations ro
     WHERE ro.conversation_id = p_conv
       AND ro.status NOT IN ('completed','cancelled')
       -- (202) or the recharge the customer's numbers opened
       -- (209) or the combo the customer is ordering
       AND (ro.service_type = 'remesa' OR (v_recarga AND ro.service_type = 'recarga')
            OR (v_combo AND ro.service_type = 'combo')
            -- (213) or the visa the customer is paying for
            OR (v_visa AND ro.service_type = 'visa')
            -- (273) or the Mexico send the customer is paying for
            OR (v_mexico AND ro.service_type = 'mexico'))
       AND NOT EXISTS (
         SELECT 1 FROM remittance_operation_receipts r
          WHERE r.operation_id = ro.id AND r.comp_id IS NOT NULL)
       AND NOT (
         (EXISTS (
           SELECT 1 FROM remittance_beneficiaries b
            WHERE b.operation_id = ro.id AND b.status = 'vigente'))
         -- COALESCE is load-bearing: cerebro_saldo_operacion returns NULL
         -- when the operation has no open objetivo, and `TRUE AND NULL`
         -- evaluates to NULL, which excludes the row and pushes a
         -- beneficiary-first operation into 'creado' (a phantom second
         -- remesa). 156's equivalent could never be NULL (deals.value is
         -- NOT NULL, notes is COALESCEd), so the guard must stay
         -- two-valued here too.
         AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_operacion(ro.id) s), 0) > 0)
         -- (232) ... and only when the operation already holds money (or is not safe to overwrite).
         AND (COALESCE(ro.quoted_source_amount, 0) > 0
              OR EXISTS (SELECT 1 FROM remittance_operation_receipts r2 WHERE r2.operation_id = ro.id)
              OR COALESCE((SELECT s.depositado FROM cerebro_saldo_operacion(ro.id) s), 0) > 0
              OR ro.status = 'incident'
              OR COALESCE(ro.admin_locked_fields, '{}'::jsonb) ? 'quoted_source_amount'))
     -- (267) the operation the resolver names (destino_operacion) first, when it is still open and eligible above
     ORDER BY (ro.id = v_dest) DESC NULLS LAST, ro.created_at DESC LIMIT 1;
  END IF;

  -- (182 <- 170) The open WAITING remesa this deposit completes: a remesa of this chat still
  -- being verified or in incident, opened in the window, with a receipt already, that is below
  -- its service minimum, still owes saldo, or this deposit alone is below the smallest minimum.
  -- A remesa that is ready to transfer is never touched. (160's version only took
  -- deposit_verification with saldo > 0 and then OVERWROTE the amount with this deposit.)
  IF NOT v_rev AND v_ex IS NULL THEN
    SELECT ro.id INTO v_suma
      FROM remittance_operations ro
     WHERE ro.conversation_id = p_conv
       AND ro.service_type = 'remesa'
       AND ro.status IN ('deposit_verification', 'incident')
       AND ro.created_at > now() - make_interval(hours => v_ventana)
       AND EXISTS (SELECT 1 FROM remittance_operation_receipts r WHERE r.operation_id = ro.id)  -- it has a deposit (170: notes LIKE '%DEPOSITO%')
       AND COALESCE(ro.incident_reason, '') NOT LIKE 'REFERENCIA IMPOSIBLE%'
       AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_operacion(ro.id) s), 0) > 0
            OR ro.quoted_source_amount < cerebro_minimo_gyd(ro.id)
            OR p_monto < v_min_cup)
     ORDER BY ro.created_at DESC LIMIT 1;
  END IF;

  -- (160) Recarga 24 h window: now decided up front by the resolver (267).

  SELECT c.phone, v.contact_id INTO v_phone, v_contact
    FROM conversations v JOIN contacts c ON c.id = v.contact_id WHERE v.id = p_conv;

  -- (160) movido branch: update the found op directly.
  IF v_ex IS NOT NULL THEN
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident'
                                  THEN v_motivo ELSE NULL END,
           quoted_source_amount = p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.id = v_ex;
    -- (156) dual-write: insert parsed receipts for this operation (before the conversion: the resolver reads them).
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_ex
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    -- (267) the resolver said convert: the deposit is attached, so the service is decided again and converted here
    IF v_accion = 'convertir' THEN
      PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
    END IF;
    PERFORM cerebro_objetivo_atar_op(p_conv, v_ex);
    -- (182 <- 170) Below the minimum of its service: wait for the rest.
    PERFORM cerebro_objetivo_minimo(p_conv, v_ex);
    -- (202) a recharge takes any number typed since (no repeats)
    IF (SELECT service_type FROM remittance_operations WHERE id = v_ex) = 'recarga' THEN
      PERFORM crm_registrar_numeros_recarga(p_conv, cerebro_textos_cliente_recientes(p_conv));
    END IF;
    -- (277) a split planned before the deposit is applied when this deposit is exactly its total
    PERFORM _cerebro_aplicar_plan_reparto(p_conv, v_ex);
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  -- (160) sumado branch: update the found op directly.
  IF v_suma IS NOT NULL THEN
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident'
                                  THEN v_motivo ELSE NULL END,
           quoted_source_amount = ro.quoted_source_amount + p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.id = v_suma;
    -- (156) dual-write (before the conversion: the resolver reads the receipts).
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_suma
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    -- (267) the resolver said convert: the deposit is attached, so the service is decided again and converted here
    IF v_accion = 'convertir' THEN
      PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
    END IF;
    PERFORM cerebro_objetivo_atar_op(p_conv, v_suma);
    -- (182 <- 170) The objetivo covers the whole remesa.
    PERFORM cerebro_objetivo_minimo(p_conv, v_suma, true);
    -- (182 <- 170) The earlier receipts of the remesa that were never crossed are crossed now;
    -- this one is crossed by the Cerebro's own node right after this call.
    PERFORM cerebro_cruzar_pendientes(v_suma, v_ref);
    PERFORM _cerebro_aplicar_plan_reparto(p_conv, v_suma);
    RETURN QUERY SELECT v_suma, 'sumado al envio abierto'::text, false, true; RETURN;
  END IF;

  -- (160) creado branch: INSERT remittance_operations directly, no deal.
  INSERT INTO remittance_operations (
    account_id, conversation_id, contact_id, deal_id, status,
    service_type, quoted_source_amount, source_currency, destination_currency, created_at,
    completed_at, cancelled_at, incident_reason
  )
  VALUES (
    (SELECT account_id FROM conversations WHERE id = p_conv),
    p_conv, v_contact, NULL,   -- deal_id = NULL (the whole point)
    cerebro_estado_desde_etapa(p_stage),
    CASE WHEN v_rev THEN 'remesa' WHEN v_combo THEN 'combo' WHEN v_visa THEN 'visa' WHEN v_mexico THEN 'mexico' WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
    p_monto, coalesce(p_moneda, 'GYD'), CASE WHEN v_mexico AND NOT v_rev THEN 'MXN' END, now(),
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'completed' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'cancelled' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident' THEN v_motivo ELSE NULL END
  )
  RETURNING id INTO v_id;

  -- (267) the resolver said convert: the deposit is attached to v_id, so the service is decided again and converted here
  IF v_accion = 'convertir' AND NOT v_rev THEN
    PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
  END IF;

  IF NOT v_rev THEN PERFORM cerebro_objetivo_atar_op(p_conv, v_id); END IF;

  -- (201) A new recharge takes the Cuban numbers the customer TYPED since asking for it (same window as v_recarga).
  IF v_recarga AND NOT v_rev THEN
    PERFORM crm_registrar_numeros_recarga(p_conv, cerebro_textos_cliente_recientes(p_conv));
  END IF;

  -- (156) dual-write: parse and insert receipts linked to this new op.
  INSERT INTO public.remittance_operation_receipts (
    operation_id, conversation_id, comp_id, amount, currency, receipt_status,
    recipient, via, reference, receipt_date, correct_destination, source)
  SELECT v_id, p_conv, p.comp_id, p.amount, p.currency, p.receipt_status,
         p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
    FROM cerebro_parsear_comprobantes(v_nota) p
  ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;

  -- (182 <- 170) Below the minimum of its service: wait for the rest.
  IF NOT v_rev THEN PERFORM cerebro_objetivo_minimo(p_conv, v_id); END IF;

  -- (160) OUT column keeps its name 'deal_id' but now carries the
  -- operation id. Callers (n8n node) pass it back to
  -- cerebro_cruzar_deposito which now calls cerebro_resolve_op_id.
  IF NOT v_rev THEN PERFORM _cerebro_aplicar_plan_reparto(p_conv, v_id); END IF;
  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

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
  v_min_cup numeric; v_min_usd numeric; v_min_rec numeric; v_min_efe numeric; v_saldo numeric; v_min_mex numeric;
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
BEGIN
  -- Initialised here, not in DECLARE: an error in a declaration is not caught by the EXCEPTION clause below.
  v_hoy := (p_ahora AT TIME ZONE 'America/Guyana')::date;
  v_min_cup := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_min_usd := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                        NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000);
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
                   WHEN 'zelle' THEN v_min_usd WHEN 'clasica' THEN v_min_usd WHEN 'tropical' THEN v_min_usd
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
      'intencion', CASE WHEN v_y IS NOT NULL THEN v_int END),
    'reparto_planeado', v_plan);
EXCEPTION WHEN OTHERS THEN
  -- Fail open: the bot keeps working without the resolver's answer.
  RETURN jsonb_build_object(
    'version', 2, 'servicio', NULL, 'en_curso', NULL, 'accion', 'ninguna', 'permitido', false, 'motivo', 'error',
    'mensaje', NULL, 'minimo_gyd', NULL, 'faltante_gyd', NULL, 'destino_operacion', NULL, 'convertir_a', NULL,
    'cancelar', '[]'::jsonb, 'grupo_mixto', NULL, 'adicionales', '[]'::jsonb, 'operaciones', '[]'::jsonb,
    'evidencia', '{}'::jsonb, 'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200));
END $function$;
