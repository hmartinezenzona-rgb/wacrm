-- =====================================================================
-- ROLLBACK-114 — reverts 114_cutover_retire_sync_pipeline.sql
--
-- Restores every function/trigger/view 114 replaced to its immediately
-- prior body, verbatim:
--   - deals_stage_notify trigger (function captured by 114 itself, left
--     in place; only the trigger needs recreating) + drops 114's
--     remittance_operations relay.
--   - trg_notify_deal_incidencia trigger (function 090 untouched, left
--     in place) + drops 114's remittance_operations Incidencia trigger.
--   - trg_sync_operacion_desde_deal, restored to 060's full
--     INSERT/UPDATE/DELETE body + drops 114's DELETE-only replacement.
--   - cerebro_registrar_deposito / cerebro_cruzar_deposito /
--     cerebro_cruzar_depositos, restored to 110's bodies.
--   - crm_entregar_operacion, restored to 108's body.
--   - crm_verificar_deposito / crm_forzar_verificacion, restored to
--     099's bodies.
--   - cerebro_historial_operaciones / cerebro_volumen_diario, restored
--     to 053's definitions.
--   - cerebro_conciliacion_operaciones, restored to 063's definition.
--
-- Does NOT drop remittance_admin_audit, remittance_operations columns,
-- or any table — 114 created no tables and dropped no columns, only
-- triggers/functions/views.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Notifications
-- ---------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_notify_operation_status_change ON remittance_operations;
DROP FUNCTION IF EXISTS notify_operation_status_change();

CREATE TRIGGER deals_stage_notify
  AFTER UPDATE OF stage_id ON public.deals
  FOR EACH ROW
  WHEN (old.stage_id IS DISTINCT FROM new.stage_id)
  EXECUTE FUNCTION notify_deal_stage_change();

DROP TRIGGER IF EXISTS trg_notify_operation_incidencia ON remittance_operations;
DROP FUNCTION IF EXISTS notify_operation_incidencia();

CREATE TRIGGER trg_notify_deal_incidencia
  AFTER INSERT OR UPDATE OF stage_id ON deals
  FOR EACH ROW EXECUTE FUNCTION public.notify_deal_incidencia();


-- ---------------------------------------------------------------------
-- 2. deals -> remittance_operations bridge (060's full body)
-- ---------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_cancel_operacion_on_deal_delete ON deals;
DROP FUNCTION IF EXISTS cerebro_cancel_operacion_on_deal_delete();

CREATE OR REPLACE FUNCTION public.cerebro_sync_operacion_desde_deal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    BEGIN
      IF OLD.pipeline_id IS DISTINCT FROM '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid THEN
        RETURN NULL;
      END IF;
      UPDATE remittance_operations
         SET status = 'cancelled', cancelled_at = now(), updated_at = now()
       WHERE deal_id = OLD.id
         AND status NOT IN ('completed','cancelled');
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[cerebro] cancelar operacion fallo al borrar deal % : %', OLD.id, SQLERRM;
    END;
    RETURN NULL;
  END IF;

  IF NEW.pipeline_id <> '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid THEN RETURN NULL; END IF;
  IF NEW.conversation_id IS NULL THEN RETURN NULL; END IF;

  v_status := cerebro_estado_desde_etapa(NEW.stage_id);

  IF TG_OP = 'INSERT' THEN
    INSERT INTO remittance_operations (
      account_id, conversation_id, contact_id, deal_id, status,
      quoted_source_amount, source_currency, created_at, completed_at, cancelled_at)
    VALUES (NEW.account_id, NEW.conversation_id, NEW.contact_id, NEW.id, v_status,
      NEW.value, coalesce(NEW.currency,'GYD'), coalesce(NEW.created_at, now()),
      CASE WHEN v_status='completed' THEN now() END,
      CASE WHEN v_status='cancelled' THEN now() END)
    ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO NOTHING;
  ELSE
    UPDATE remittance_operations o
       SET status = v_status,
           quoted_source_amount = NEW.value,
           contact_id = coalesce(NEW.contact_id, o.contact_id)
     WHERE o.deal_id = NEW.id
       AND (o.status IS DISTINCT FROM v_status
            OR o.quoted_source_amount IS DISTINCT FROM NEW.value
            OR o.contact_id IS DISTINCT FROM coalesce(NEW.contact_id, o.contact_id));

    INSERT INTO remittance_operations (
      account_id, conversation_id, contact_id, deal_id, status,
      quoted_source_amount, source_currency, created_at)
    SELECT NEW.account_id, NEW.conversation_id, NEW.contact_id, NEW.id, v_status,
           NEW.value, coalesce(NEW.currency,'GYD'), coalesce(NEW.created_at, now())
     WHERE NOT EXISTS (SELECT 1 FROM remittance_operations WHERE deal_id = NEW.id)
    ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO NOTHING;
  END IF;

  PERFORM cerebro_sync_beneficiarios(NEW.id);

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] sync operacion fallo para deal % : %', NEW.id, SQLERRM;
  RETURN NULL;
END $function$;

DROP TRIGGER IF EXISTS trg_sync_operacion_desde_deal ON public.deals;
CREATE TRIGGER trg_sync_operacion_desde_deal
  AFTER INSERT OR DELETE OR UPDATE OF stage_id, value, contact_id, currency ON public.deals
  FOR EACH ROW EXECUTE FUNCTION cerebro_sync_operacion_desde_deal();


-- ---------------------------------------------------------------------
-- 3. cerebro_registrar_deposito / cerebro_cruzar_deposito /
--    cerebro_cruzar_depositos — restored to 110's bodies verbatim.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito(p_conv uuid, p_monto numeric, p_moneda text, p_stage uuid, p_nota text, p_comp_id text)
 RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rev     boolean;
  v_recarga boolean := false;
  v_ya      uuid;
  v_ex      uuid;
  v_suma    uuid;
  v_id      uuid;
  v_phone   text;
  v_ref     text;
  v_nota    text;
BEGIN
  v_rev := cerebro_es_revendedor(p_conv);

  v_nota := COALESCE(p_nota,'');
  IF NULLIF(p_comp_id,'') IS NOT NULL AND v_nota NOT LIKE '%'||p_comp_id||'%' THEN
    v_nota := v_nota || chr(10) || p_comp_id;
  END IF;

  IF NOT cerebro_transid_plausible(NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '')) THEN
    p_stage := 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid;
    v_nota := v_nota || chr(10)
      || 'REFERENCIA IMPOSIBLE: ese numero no puede ser un TransID de MMG. El contador '
      || 'solo crece y este queda por debajo de todos los recibidos, asi que casi seguro '
      || 'lo leyo la vision de una CAPTURA o de una foto de otra pantalla, no de un '
      || 'comprobante directo. NO se ha registrado como deposito normal: mire la imagen y '
      || 'pidale al cliente el comprobante original antes de dar nada por recibido.';
  END IF;

  IF NULLIF(p_comp_id,'') IS NOT NULL THEN
    SELECT d.id INTO v_ya FROM deals d
     WHERE d.conversation_id = p_conv
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND COALESCE(d.notes,'') LIKE '%'||p_comp_id||'%'
     LIMIT 1;
    IF v_ya IS NOT NULL THEN
      RETURN QUERY SELECT v_ya, 'ya registrado (idempotente)'::text, v_rev, false; RETURN;
    END IF;
  END IF;

  IF NOT v_rev THEN
    SELECT d.id INTO v_ex
      FROM deals d
     WHERE d.conversation_id = p_conv
       AND d.status = 'open'
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND d.stage_id IN ('96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109',
                          '3cf01654-cd27-47c1-ac92-62abf5435751',
                          'f5cf87f8-b570-4d71-b6ea-a3cafd458c63')
       AND COALESCE(d.notes,'') NOT LIKE '%DEPOSITO%'
       AND NOT (d.value > 0 AND COALESCE(d.notes,'') LIKE '%BENEFICIARIO%')
     ORDER BY d.created_at DESC LIMIT 1;
  END IF;

  IF NOT v_rev AND v_ex IS NULL THEN
    SELECT d.id INTO v_suma
      FROM deals d
     WHERE d.conversation_id = p_conv
       AND d.status = 'open'
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND d.stage_id = '3cf01654-cd27-47c1-ac92-62abf5435751'
       AND (SELECT s.saldo FROM cerebro_saldo_envio(d.id) s) > 0
     ORDER BY d.created_at DESC LIMIT 1;
  END IF;

  IF v_ex IS NOT NULL THEN
    UPDATE deals
       SET stage_id = p_stage, value = p_monto, currency = p_moneda,
           notes = COALESCE(notes,'') || E'\n---\n' || v_nota, updated_at = now()
     WHERE id = v_ex;
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage)
     WHERE ro.deal_id = v_ex;
    PERFORM cerebro_objetivo_atar(p_conv, v_ex);
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  IF v_suma IS NOT NULL THEN
    UPDATE deals
       SET stage_id = p_stage,
           value    = COALESCE(value, 0) + p_monto,
           currency = p_moneda,
           notes    = COALESCE(notes,'') || E'\n---\n' || v_nota,
           updated_at = now()
     WHERE id = v_suma;
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage)
     WHERE ro.deal_id = v_suma;
    PERFORM cerebro_objetivo_atar(p_conv, v_suma);
    RETURN QUERY SELECT v_suma, 'sumado al envio abierto'::text, false, true; RETURN;
  END IF;

  IF NOT v_rev THEN
    SELECT EXISTS (
             SELECT 1 FROM messages m
              WHERE m.conversation_id = p_conv
                AND m.sender_type = 'customer'
                AND m.created_at > GREATEST(
                      now() - interval '24 hours',
                      COALESCE((SELECT max(d9.updated_at) FROM deals d9
                                 WHERE d9.conversation_id = p_conv
                                   AND (d9.status <> 'open'
                                        OR d9.stage_id = '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b')),
                               now() - interval '24 hours'))
                AND (m.content_text ILIKE '%recarga%'
                     OR m.content_text ILIKE '%etecsa%'
                     OR m.content_text ILIKE '%cubacel%'))
       AND NOT EXISTS (
             SELECT 1 FROM cerebro_beneficiario_parcial bp
              WHERE bp.conversation_id = p_conv
                AND COALESCE(bp.tarjeta,'') <> '')
      INTO v_recarga;
  END IF;

  SELECT c.phone INTO v_phone
    FROM conversations v JOIN contacts c ON c.id = v.contact_id WHERE v.id = p_conv;
  v_ref := NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '');

  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                     stage_id, title, value, currency, notes, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id,
         '78220927-0745-45a8-ba08-a1b33734dbf1', p_stage,
         CASE WHEN v_rev
              THEN 'Remesa REVENDEDOR - Ref ' || COALESCE(v_ref, to_char(now(),'DDMM-HH24MI'))
              WHEN v_recarga
              THEN 'Recarga +' || COALESCE(v_phone,'?')
              ELSE 'Remesa +' || COALESCE(v_phone,'?') END,
         p_monto, p_moneda, v_nota, 'open'
    FROM conversations v WHERE v.id = p_conv
  RETURNING id INTO v_id;

  IF NOT v_rev THEN PERFORM cerebro_objetivo_atar(p_conv, v_id); END IF;

  IF v_recarga THEN
    UPDATE remittance_operations ro
       SET service_type = 'recarga'
     WHERE ro.deal_id = v_id;
  END IF;

  UPDATE remittance_operations ro
     SET status = cerebro_estado_desde_etapa(p_stage)
   WHERE ro.deal_id = v_id;

  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_cruzar_deposito(p_deal uuid, p_ref text, p_monto numeric, p_stage_ok uuid, p_stage_incidencia uuid, p_stage_esperado uuid, p_simular boolean DEFAULT false)
 RETURNS TABLE(resultado text, trans_id text, deal_actualizado integer, metodo text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ref        text;
  v_aplica     boolean;
  v_res        text;
  v_trans      text;
  v_recibido   timestamptz;
  v_metodo     text := 'exacto';
  v_nota       text;
  v_stage      uuid;
  v_tocados    int  := 0;
  v_horas      int;
  v_maxhoras   int;
  v_candidatos int := 0;
  v_conv       uuid;
  v_phone      text;
BEGIN
  v_ref := NULLIF(regexp_replace(COALESCE(p_ref, ''), '[^0-9]', '', 'g'), '');

  SELECT COALESCE((SELECT stage_id FROM deals WHERE id = p_deal) = p_stage_esperado, false)
    INTO v_aplica;

  IF NOT v_aplica THEN
    RETURN QUERY SELECT 'no_aplica'::text, v_ref, 0, 'ninguno'::text; RETURN;
  END IF;

  IF v_ref IS NULL THEN
    RETURN QUERY SELECT 'sin_referencia'::text, v_ref, 0, 'ninguno'::text; RETURN;
  END IF;

  v_maxhoras := COALESCE(NULLIF(cerebro_config_get('cruce_antiguedad_max_horas'), '')::int, 72);

  SELECT d.trans_id, d.recibido_en INTO v_trans, v_recibido
    FROM depositos_mmg d
   WHERE d.trans_id = v_ref AND d.consumido_en IS NULL AND d.monto = p_monto
     AND d.anulado_en IS NULL
   FOR UPDATE;

  IF v_trans IS NOT NULL AND v_recibido < now() - make_interval(hours => v_maxhoras) THEN
    v_res    := 'deposito_antiguo';
    v_metodo := 'antiguo';
  ELSIF v_trans IS NOT NULL THEN
    IF NOT p_simular THEN
      UPDATE depositos_mmg d SET deal_id = p_deal, consumido_en = now()
       WHERE d.trans_id = v_trans AND d.consumido_en IS NULL;
    END IF;
    v_res := 'verificado';
  ELSIF EXISTS (SELECT 1 FROM depositos_mmg x
                 WHERE x.trans_id = v_ref AND x.anulado_en IS NOT NULL) THEN
    v_res := 'deposito_anulado';
  ELSIF EXISTS (SELECT 1 FROM depositos_mmg x
                 WHERE x.trans_id = v_ref AND x.consumido_en IS NOT NULL) THEN
    v_res := 'ya_reclamado';
  ELSIF EXISTS (SELECT 1 FROM depositos_mmg x WHERE x.trans_id = v_ref) THEN
    v_res := 'monto_no_coincide';
  ELSE
    v_res := 'sin_correo';
  END IF;

  IF v_res = 'sin_correo' THEN
    v_horas := COALESCE(NULLIF(cerebro_config_get('cruce_ventana_horas'), '')::int, 6);

    SELECT count(*) INTO v_candidatos
      FROM depositos_mmg m
     WHERE m.consumido_en IS NULL
       AND m.anulado_en IS NULL
       AND m.monto        = p_monto
       AND m.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                             AND now() + interval '15 minutes'
       AND length(m.trans_id) = length(v_ref)
       AND left(m.trans_id, 5) = left(v_ref, 5)
       AND right(m.trans_id, 4) = right(v_ref, 4);

    IF v_candidatos = 1 THEN
      IF p_simular THEN
        SELECT m.trans_id INTO v_trans
          FROM depositos_mmg m
         WHERE m.consumido_en IS NULL AND m.anulado_en IS NULL AND m.monto = p_monto
           AND m.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                                 AND now() + interval '15 minutes'
           AND length(m.trans_id) = length(v_ref)
           AND left(m.trans_id, 5) = left(v_ref, 5)
           AND right(m.trans_id, 4) = right(v_ref, 4);
      ELSE
        UPDATE depositos_mmg m
           SET deal_id = p_deal, consumido_en = now()
         WHERE m.trans_id = (
                 SELECT x.trans_id FROM depositos_mmg x
                  WHERE x.consumido_en IS NULL
                    AND x.anulado_en IS NULL
                    AND x.monto = p_monto
                    AND x.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                                          AND now() + interval '15 minutes'
                    AND length(x.trans_id) = length(v_ref)
                    AND left(x.trans_id, 5) = left(v_ref, 5)
                    AND right(x.trans_id, 4) = right(v_ref, 4)
                  LIMIT 1 FOR UPDATE SKIP LOCKED)
        RETURNING m.trans_id INTO v_trans;
      END IF;

      IF v_trans IS NOT NULL THEN
        v_res := 'verificado'; v_metodo := 'aproximado';
      END IF;
    ELSIF v_candidatos > 1 THEN
      v_metodo := 'ambiguo';
    END IF;
  END IF;

  IF v_res IN ('verificado','ya_reclamado','monto_no_coincide','deposito_antiguo','deposito_anulado') THEN
    v_stage := CASE WHEN v_res = 'verificado' THEN p_stage_ok ELSE p_stage_incidencia END;

    v_nota := CASE
      WHEN v_res = 'verificado' AND v_metodo = 'aproximado' THEN
        'VERIFICADO: casa con el correo de MMG (TransID ' || v_trans || ')'
        || ' - COINCIDENCIA APROXIMADA: el comprobante decia ' || v_ref
        || '. Coinciden importe, hora, longitud, prefijo y sufijo, y era el unico'
        || ' candidato posible. CONFIRMAR VISUALMENTE el comprobante.'
      WHEN v_res = 'verificado' THEN
        'VERIFICADO: casa con el correo de MMG (TransID ' || v_ref || ')'
      WHEN v_res = 'deposito_anulado' THEN
        'SIN VERIFICAR - DEPOSITO ANULADO: el TransID ' || v_ref || ' figura como'
        || ' ANULADO en el libro de MMG. NO se ha dado por bueno. Motivo registrado: '
        || COALESCE((SELECT x.motivo_anulacion FROM depositos_mmg x WHERE x.trans_id = v_ref LIMIT 1), 'sin motivo')
      WHEN v_res = 'deposito_antiguo' THEN
        'SIN VERIFICAR - DEPOSITO ANTIGUO: el TransID ' || v_ref || ' si existe y el'
        || ' importe cuadra, pero el deposito se recibio el '
        || to_char(v_recibido AT TIME ZONE 'America/Guyana', 'DD/MM/YYYY HH24:MI')
        || ' (hace ' || floor(EXTRACT(epoch FROM (now() - v_recibido))/3600)::int || ' horas).'
        || ' NO se ha dado por bueno ni se ha consumido. Compruebe que esta remesa no'
        || ' se pago ya por otra via antes de transferir.'
      WHEN v_res = 'ya_reclamado' THEN
        'ALERTA: el TransID ' || v_ref || ' ya fue usado en otro envio'
      ELSE
        'ALERTA: el TransID ' || v_ref || ' existe en MMG pero el monto no coincide'
    END;

    IF NOT p_simular THEN
      UPDATE deals
         SET stage_id = v_stage,
             notes = COALESCE(notes,'') || chr(10) || v_nota,
             updated_at = now()
       WHERE id = p_deal;
      GET DIAGNOSTICS v_tocados = ROW_COUNT;
      UPDATE remittance_operations
         SET status = cerebro_estado_desde_etapa(v_stage)
       WHERE deal_id = p_deal;
    ELSE
      v_tocados := 1;
    END IF;
  END IF;

  IF NOT p_simular AND v_metodo IN ('aproximado','ambiguo') THEN
    SELECT d.conversation_id INTO v_conv FROM deals d WHERE d.id = p_deal;
    SELECT c.phone INTO v_phone FROM conversations v JOIN contacts c ON c.id = v.contact_id
     WHERE v.id = v_conv;

    PERFORM net.http_post(
      url     := cerebro_config_get('notify_url'),
      body    := jsonb_build_object('type','CRUCE_APROXIMADO','metodo',v_metodo,
                   'cliente_phone',COALESCE(v_phone,'?'),'monto',p_monto,
                   'ref_leida',v_ref,'ref_hallada',v_trans,'candidatos',v_candidatos),
      headers := jsonb_build_object('Content-Type','application/json',
                   'X-Cerebro-Secret', cerebro_config_get('notify_secret')));
  END IF;

  RETURN QUERY SELECT v_res, COALESCE(v_trans, v_ref), v_tocados, v_metodo;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_cruzar_depositos(p_deal uuid, p_refs text[], p_montos numeric[], p_stage_ok uuid, p_stage_incidencia uuid, p_stage_esperado uuid, p_simular boolean DEFAULT false)
 RETURNS TABLE(resultado text, trans_id text, deal_actualizado integer, metodo text, todos_verificados boolean, total_verificado numeric, n_comprobantes integer, detalle jsonb, objetivo numeric, depositado numeric, saldo numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n int; v_i int; v_c record;
  v_det jsonb := '[]'::jsonb; v_todos boolean := true; v_total numeric := 0;
  v_trans1 text := NULL; v_fallo text := NULL; v_metodo text := 'exacto';
  v_nota text; v_tocados int := 0; v_refs_ok int;
  v_obj numeric; v_dep numeric; v_saldo numeric; v_mon text;
  v_stage_final uuid;
BEGIN
  v_n := COALESCE(array_length(p_refs, 1), 0);

  SELECT s.objetivo, s.moneda INTO v_obj, v_mon FROM cerebro_saldo_envio(p_deal) s;

  IF v_n <= 1 AND v_obj IS NULL THEN
    RETURN QUERY
      SELECT c.resultado, c.trans_id, c.deal_actualizado, c.metodo,
             (c.resultado = 'verificado'),
             CASE WHEN c.resultado = 'verificado' THEN COALESCE(p_montos[1], 0) ELSE 0 END,
             v_n,
             jsonb_build_array(jsonb_build_object(
               'ref', p_refs[1], 'monto', p_montos[1],
               'resultado', c.resultado, 'trans_id', c.trans_id, 'metodo', c.metodo)),
             NULL::numeric, NULL::numeric, NULL::numeric
        FROM cerebro_cruzar_deposito(p_deal, p_refs[1], p_montos[1],
                                     p_stage_ok, p_stage_incidencia,
                                     p_stage_esperado, p_simular) c;
    RETURN;
  END IF;

  IF v_n > 1 THEN
    IF COALESCE(array_length(p_montos, 1), 0) <> v_n THEN
      v_todos := false;
      v_fallo := 'las referencias y los importes no vienen emparejados';
    END IF;
    IF v_todos THEN
      SELECT count(DISTINCT regexp_replace(COALESCE(r, ''), '[^0-9]', '', 'g'))
        INTO v_refs_ok FROM unnest(p_refs) AS r;
      IF v_refs_ok <> v_n THEN
        v_todos := false;
        v_fallo := 'la misma referencia viene repetida dentro de la rafaga';
      END IF;
    END IF;
  END IF;

  IF v_todos THEN
    FOR v_i IN 1 .. GREATEST(v_n, 1) LOOP
      SELECT * INTO v_c
        FROM cerebro_cruzar_deposito(p_deal, p_refs[v_i], p_montos[v_i],
                                     p_stage_esperado, p_stage_esperado,
                                     p_stage_esperado, true);
      v_det := v_det || jsonb_build_object(
                 'ref', p_refs[v_i], 'monto', p_montos[v_i],
                 'resultado', v_c.resultado, 'trans_id', v_c.trans_id, 'metodo', v_c.metodo);
      IF v_c.resultado = 'verificado' THEN
        v_total := v_total + COALESCE(p_montos[v_i], 0);
        IF v_trans1 IS NULL THEN v_trans1 := v_c.trans_id; END IF;
        IF v_c.metodo = 'aproximado' THEN v_metodo := 'aproximado'; END IF;
      ELSE
        v_todos := false;
        IF v_fallo IS NULL THEN v_fallo := v_c.resultado; END IF;
      END IF;
    END LOOP;
  END IF;

  IF v_todos AND NOT p_simular THEN
    BEGIN
      v_det := '[]'::jsonb; v_total := 0; v_trans1 := NULL;
      FOR v_i IN 1 .. GREATEST(v_n, 1) LOOP
        SELECT * INTO v_c
          FROM cerebro_cruzar_deposito(p_deal, p_refs[v_i], p_montos[v_i],
                                       p_stage_esperado, p_stage_esperado,
                                       p_stage_esperado, false);
        v_det := v_det || jsonb_build_object(
                   'ref', p_refs[v_i], 'monto', p_montos[v_i],
                   'resultado', v_c.resultado, 'trans_id', v_c.trans_id, 'metodo', v_c.metodo);
        IF v_c.resultado <> 'verificado' THEN
          RAISE EXCEPTION 'cruce parcial: % en %', v_c.resultado, p_refs[v_i]
            USING ERRCODE = 'data_exception';
        END IF;
        v_total := v_total + COALESCE(p_montos[v_i], 0);
        IF v_trans1 IS NULL THEN v_trans1 := v_c.trans_id; END IF;
        IF v_c.metodo = 'aproximado' THEN v_metodo := 'aproximado'; END IF;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      v_todos := false; v_total := 0; v_trans1 := NULL;
      v_fallo := COALESCE(v_fallo, 'cruce parcial revertido: ' || SQLERRM);
    END;
  END IF;

  SELECT s.objetivo, s.depositado, s.saldo INTO v_obj, v_dep, v_saldo
    FROM cerebro_saldo_envio(p_deal) s;
  IF p_simular AND v_obj IS NOT NULL THEN
    v_dep := v_dep + CASE WHEN v_todos THEN v_total ELSE 0 END;
    v_saldo := v_obj - v_dep;
  END IF;

  v_stage_final := CASE
    WHEN NOT v_todos           THEN p_stage_incidencia
    WHEN v_saldo IS NULL       THEN p_stage_ok
    WHEN v_saldo > 0           THEN p_stage_esperado
    WHEN v_saldo < 0           THEN p_stage_incidencia
    ELSE                            p_stage_ok
  END;

  v_nota := CASE
    WHEN NOT v_todos THEN
      'SIN VERIFICAR - RAFAGA DE ' || v_n || ' COMPROBANTES QUE NO CUADRA ('
      || COALESCE(v_fallo, 'motivo desconocido') || ').'
      || ' NO se ha consumido NINGUNO de los ' || v_n || ' depositos: o cruzan todos'
      || ' o no cruza ninguno. Revisar a mano antes de transferir. Detalle: ' || v_det::text
    ELSE
      CASE WHEN v_n > 1 THEN
        'TOTAL VERIFICADO: ' || v_n || ' comprobantes de la misma rafaga suman '
        || rtrim(trim(to_char(v_total, 'FM999,999,999,990.99')), '.')
        || ' y los ' || v_n || ' casan con el libro de MMG.'
        || CASE WHEN v_metodo = 'aproximado'
                THEN ' OJO: alguno cruzo por COINCIDENCIA APROXIMADA - confirmar visualmente.'
                ELSE '' END
      ELSE '' END
      ||
      CASE
        WHEN v_saldo IS NULL THEN ''
        WHEN v_saldo > 0 THEN
          CASE WHEN v_n > 1 THEN chr(10) ELSE '' END
          || 'SALDO: lleva ' || rtrim(trim(to_char(v_dep,'FM999,999,999,990.99')),'.')
          || ' de ' || rtrim(trim(to_char(v_obj,'FM999,999,999,990.99')),'.')
          || ' ' || v_mon || ', FALTAN ' || rtrim(trim(to_char(v_saldo,'FM999,999,999,990.99')),'.')
          || '. El envio SIGUE ESPERANDO el resto y NO se transfiere todavia.'
        WHEN v_saldo < 0 THEN
          CASE WHEN v_n > 1 THEN chr(10) ELSE '' END
          || 'DEPOSITO DE MAS: el objetivo eran '
          || rtrim(trim(to_char(v_obj,'FM999,999,999,990.99')),'.')
          || ' ' || v_mon || ' y lleva depositados '
          || rtrim(trim(to_char(v_dep,'FM999,999,999,990.99')),'.')
          || ' — sobran ' || rtrim(trim(to_char(-v_saldo,'FM999,999,999,990.99')),'.')
          || '. NO hay politica para el dinero de mas: lo decide una persona.'
        ELSE
          CASE WHEN v_n > 1 THEN chr(10) ELSE '' END
          || 'OBJETIVO CUBIERTO: ' || rtrim(trim(to_char(v_dep,'FM999,999,999,990.99')),'.')
          || ' ' || v_mon || ' de ' || rtrim(trim(to_char(v_obj,'FM999,999,999,990.99')),'.')
          || '. El envio queda listo para transferir.'
      END
  END;

  IF NOT p_simular THEN
    UPDATE deals
       SET stage_id = v_stage_final,
           notes = COALESCE(notes, '') || CASE WHEN v_nota = '' THEN '' ELSE chr(10) || v_nota END,
           updated_at = now()
     WHERE id = p_deal;
    GET DIAGNOSTICS v_tocados = ROW_COUNT;
    UPDATE remittance_operations
       SET status = cerebro_estado_desde_etapa(v_stage_final)
     WHERE deal_id = p_deal;
    IF v_todos AND v_saldo IS NOT NULL AND v_saldo = 0 THEN
      PERFORM cerebro_objetivo_cerrar(p_deal);
    END IF;
  ELSE
    v_tocados := 1;
  END IF;

  RETURN QUERY SELECT
    CASE WHEN NOT v_todos THEN COALESCE(v_fallo, 'sin_cruce')
         WHEN v_saldo IS NOT NULL AND v_saldo > 0 THEN 'verificado_incompleto'
         WHEN v_saldo IS NOT NULL AND v_saldo < 0 THEN 'verificado_de_mas'
         ELSE 'verificado' END,
    v_trans1, v_tocados, v_metodo, v_todos, v_total, v_n, v_det,
    v_obj, v_dep, v_saldo;
END;
$function$;

REVOKE EXECUTE ON FUNCTION
  cerebro_cruzar_deposito(uuid,text,numeric,uuid,uuid,uuid,boolean),
  cerebro_cruzar_depositos(uuid,text[],numeric[],uuid,uuid,uuid,boolean),
  cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  cerebro_cruzar_deposito(uuid,text,numeric,uuid,uuid,uuid,boolean),
  cerebro_cruzar_depositos(uuid,text[],numeric[],uuid,uuid,uuid,boolean),
  cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text)
TO service_role;


-- ---------------------------------------------------------------------
-- 4. crm_entregar_operacion — restored to 108's body verbatim.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lista         CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_entregada     CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';

  v_account_id    uuid;
  v_deal_id       uuid;
  v_conversation  uuid;

  v_stage         uuid;
  v_locked_deal   uuid;

  v_status_before text;
  v_status_after  text;
  v_completed_at  timestamptz;

  v_mode          text;
  v_wamid         text;
  v_path          text;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to deliver this operation' USING ERRCODE = '42501';
  END IF;

  IF v_deal_id IS NULL THEN
    RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE = '22023';
  END IF;

  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'evidence must be a JSON object' USING ERRCODE = '22023';
  END IF;

  v_mode := p_evidence ->> 'mode';
  IF v_mode IS NULL OR v_mode NOT IN ('proof_sent', 'no_proof', 'skip_proof') THEN
    RAISE EXCEPTION 'evidence mode must be proof_sent, no_proof or skip_proof' USING ERRCODE = '22023';
  END IF;

  IF p_evidence ? 'wamid' AND (p_evidence -> 'wamid') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'wamid') <> 'string' THEN
      RAISE EXCEPTION 'evidence wamid must be a string' USING ERRCODE = '22023';
    END IF;
    v_wamid := p_evidence ->> 'wamid';
    IF v_wamid = '' OR length(v_wamid) > 500 THEN
      RAISE EXCEPTION 'evidence wamid must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_evidence ? 'path' AND (p_evidence -> 'path') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'path') <> 'string' THEN
      RAISE EXCEPTION 'evidence path must be a string' USING ERRCODE = '22023';
    END IF;
    v_path := p_evidence ->> 'path';
    IF v_path = '' OR length(v_path) > 500 THEN
      RAISE EXCEPTION 'evidence path must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT stage_id, conversation_id INTO v_stage, v_conversation FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status, deal_id
    INTO v_status_before, v_locked_deal
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_locked_deal IS DISTINCT FROM v_deal_id THEN
    RAISE EXCEPTION 'operation changed concurrently, retry' USING ERRCODE = '40001';
  END IF;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' OR v_stage IS DISTINCT FROM v_lista THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_operations
     SET delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid()
   WHERE id = p_operation_id;

  UPDATE deals SET stage_id = v_entregada, updated_at = now() WHERE id = v_deal_id;

  SELECT status, completed_at INTO v_status_after, v_completed_at FROM remittance_operations WHERE id = p_operation_id;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer', 'deal_stage', v_lista),
          jsonb_build_object('status', 'completed', 'deal_stage', v_entregada, 'evidence', p_evidence));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $$;

REVOKE ALL ON FUNCTION crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_entregar_operacion(uuid, jsonb) TO authenticated;


-- ---------------------------------------------------------------------
-- 5. crm_verificar_deposito / crm_forzar_verificacion — restored to
--    099's bodies verbatim.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_verificar_deposito(p_operation_id uuid, p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_por_verificar CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista         CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_incidencia    CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';

  v_account_id      uuid;
  v_status_before   text;
  v_status_after    text;
  v_deal_id         uuid;
  v_stage           uuid;
  v_final           uuid;

  v_items_len   integer;
  v_i           integer;
  v_item        jsonb;
  v_ref         text;
  v_amount      numeric;
  v_refs        text[] := ARRAY[]::text[];
  v_montos      numeric[] := ARRAY[]::numeric[];
  v_locked_deal uuid;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to verify deposits on this operation' USING ERRCODE = '42501';
  END IF;

  IF v_deal_id IS NULL THEN
    RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE = '22023';
  END IF;

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status, deal_id
    INTO v_status_before, v_locked_deal
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_locked_deal IS DISTINCT FROM v_deal_id THEN
    RAISE EXCEPTION 'operation changed concurrently, retry' USING ERRCODE = '40001';
  END IF;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  IF v_stage IS NULL OR v_stage NOT IN (v_por_verificar, v_incidencia) THEN
    RAISE EXCEPTION 'deal is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'items must be a JSON array' USING ERRCODE = '22023';
  END IF;

  v_items_len := jsonb_array_length(p_items);
  IF v_items_len < 1 OR v_items_len > 5 THEN
    RAISE EXCEPTION 'items must contain between 1 and 5 entries' USING ERRCODE = '22023';
  END IF;

  FOR v_i IN 0 .. v_items_len - 1 LOOP
    v_item := p_items -> v_i;

    v_ref := regexp_replace(coalesce(v_item ->> 'ref', ''), '[^0-9]', '', 'g');
    IF v_ref = '' THEN
      RAISE EXCEPTION 'each item ref must contain at least one digit' USING ERRCODE = '22023';
    END IF;

    BEGIN
      v_amount := (v_item ->> 'amount')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'each item amount must be a positive number' USING ERRCODE = '22023';
    END;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'each item amount must be greater than 0' USING ERRCODE = '22023';
    END IF;

    v_refs := v_refs || v_ref;
    v_montos := v_montos || v_amount;
  END LOOP;

  DECLARE
    v_resultado          text;
    v_metodo             text;
    v_todos_verificados  boolean;
    v_total_verificado   numeric;
    v_n_comprobantes     integer;
    v_detalle            jsonb;
    v_objetivo           numeric;
    v_depositado         numeric;
    v_saldo              numeric;
  BEGIN
    SELECT resultado, metodo, todos_verificados, total_verificado, n_comprobantes,
           detalle, objetivo, depositado, saldo
      INTO v_resultado, v_metodo, v_todos_verificados, v_total_verificado, v_n_comprobantes,
           v_detalle, v_objetivo, v_depositado, v_saldo
      FROM cerebro_cruzar_depositos(v_deal_id, v_refs, v_montos, v_stage, v_stage, v_stage, false);

    v_final := CASE v_resultado
                 WHEN 'verificado' THEN v_lista
                 WHEN 'verificado_de_mas' THEN v_incidencia
                 ELSE v_stage
               END;

    IF v_final = v_lista AND v_stage <> v_lista THEN
      UPDATE deals
         SET stage_id = v_lista,
             notes = replace(coalesce(notes, ''),
                              'VERIFICADO: casa con el correo de MMG',
                              'VERIFICADO EN PANEL: casa con el correo de MMG')
                     || chr(10) || 'VERIFICADO EN PANEL por un operador del CRM',
             updated_at = now()
       WHERE id = v_deal_id;
    ELSIF v_final <> v_stage THEN
      UPDATE deals SET stage_id = v_final, updated_at = now() WHERE id = v_deal_id;
    END IF;

    SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_deposit_verification',
            wacrm_current_actor(),
            jsonb_build_object('status', v_status_before, 'deal_stage', v_stage),
            jsonb_build_object('status', v_status_after, 'deal_stage', v_final,
                                'resultado', v_resultado, 'metodo', v_metodo, 'detalle', v_detalle,
                                'objetivo', v_objetivo, 'depositado', v_depositado, 'saldo', v_saldo));

    RETURN jsonb_build_object(
      'resultado', v_resultado,
      'metodo', v_metodo,
      'todos_verificados', v_todos_verificados,
      'total_verificado', v_total_verificado,
      'n_comprobantes', v_n_comprobantes,
      'detalle', v_detalle,
      'objetivo', v_objetivo,
      'depositado', v_depositado,
      'saldo', v_saldo,
      'stage_changed', (v_final <> v_stage),
      'new_status', v_status_after
    );
  END;
END $$;

CREATE OR REPLACE FUNCTION crm_forzar_verificacion(p_operation_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_por_verificar CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista         CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_incidencia    CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';

  v_account_id     uuid;
  v_status_before  text;
  v_status_after   text;
  v_deal_id        uuid;
  v_stage          uuid;
  v_reason         text;
  v_locked_deal    uuid;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to force-verify this operation' USING ERRCODE = '42501';
  END IF;

  v_reason := btrim(coalesce(p_reason, ''));
  IF length(v_reason) < 5 THEN
    RAISE EXCEPTION 'reason must be at least 5 characters' USING ERRCODE = '22023';
  END IF;

  IF v_deal_id IS NULL THEN
    RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE = '22023';
  END IF;

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status, deal_id
    INTO v_status_before, v_locked_deal
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_locked_deal IS DISTINCT FROM v_deal_id THEN
    RAISE EXCEPTION 'operation changed concurrently, retry' USING ERRCODE = '40001';
  END IF;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  IF v_stage IS NULL OR v_stage NOT IN (v_por_verificar, v_incidencia) THEN
    RAISE EXCEPTION 'deal is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  UPDATE deals
     SET stage_id = v_lista,
         notes = replace(coalesce(notes, ''),
                          'VERIFICADO: casa con el correo de MMG',
                          'VERIFICADO EN PANEL: casa con el correo de MMG')
                 || chr(10) || 'VERIFICACION FORZADA EN PANEL: ' || v_reason,
         updated_at = now()
   WHERE id = v_deal_id;

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_forced_verification',
          wacrm_current_actor(), v_reason,
          jsonb_build_object('status', v_status_before, 'deal_stage', v_stage),
          jsonb_build_object('status', v_status_after, 'deal_stage', v_lista));

  RETURN jsonb_build_object('new_status', v_status_after);
END $$;

REVOKE ALL ON FUNCTION crm_verificar_deposito(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_verificar_deposito(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION crm_forzar_verificacion(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_forzar_verificacion(uuid, text) TO authenticated;


-- ---------------------------------------------------------------------
-- 6. Views — restored to 053/063's definitions verbatim.
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW cerebro_historial_operaciones AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  o.status,
  ct.name   AS cliente,
  ct.phone  AS telefono,
  coalesce(d.value, o.quoted_source_amount, 0) AS monto_gyd,
  o.destination_currency,
  b.beneficiary_type,
  b.name    AS beneficiario,
  CASE WHEN b.card_number IS NOT NULL
       THEN left(b.card_number,4) || '****' || right(b.card_number,4) END AS tarjeta,
  b.phone   AS celular_beneficiario,
  b.zelle_account,
  o.deal_id,
  o.id      AS operation_id,
  o.created_at,
  o.completed_at
FROM remittance_operations o
LEFT JOIN deals d          ON d.id = o.deal_id
LEFT JOIN conversations cv ON cv.id = o.conversation_id
LEFT JOIN contacts ct      ON ct.id = coalesce(o.contact_id, cv.contact_id)
LEFT JOIN remittance_beneficiaries b
       ON b.operation_id = o.id AND b.status = 'vigente';

CREATE OR REPLACE VIEW cerebro_volumen_diario AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  count(*)                                                 AS operaciones,
  sum(coalesce(d.value, o.quoted_source_amount, 0))        AS volumen_gyd,
  round(avg(coalesce(d.value, o.quoted_source_amount, 0))) AS ticket_medio_gyd
FROM remittance_operations o
LEFT JOIN deals d ON d.id = o.deal_id
WHERE o.status = 'completed'
GROUP BY 1, 2;

CREATE OR REPLACE VIEW cerebro_conciliacion_operaciones AS
 SELECT 'deal sin operacion'::text AS problema, d.id AS deal_id, NULL::uuid AS operation_id
   FROM deals d
   LEFT JOIN remittance_operations o ON o.deal_id = d.id
  WHERE d.conversation_id IS NOT NULL
    AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid
    AND o.id IS NULL
 UNION ALL
 SELECT 'operacion sin deal', NULL::uuid, o.id
   FROM remittance_operations o
   LEFT JOIN deals d ON d.id = o.deal_id
  WHERE o.deal_id IS NOT NULL AND d.id IS NULL
    AND o.status NOT IN ('completed','cancelled')
 UNION ALL
 SELECT 'estado divergente', d.id, o.id
   FROM remittance_operations o
   JOIN deals d ON d.id = o.deal_id
  WHERE o.status <> CASE d.stage_id
      WHEN '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109'::uuid THEN 'collecting_information'
      WHEN '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid THEN 'deposit_verification'
      WHEN 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63'::uuid THEN 'ready_to_transfer'
      WHEN '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b'::uuid THEN 'completed'
      WHEN 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid THEN 'incident'
      ELSE 'collecting_information' END;

NOTIFY pgrst, 'reload schema';
