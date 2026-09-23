-- =====================================================================
-- 110 — Repoint the n8n-called cerebro_* functions onto
-- remittance_operations directly (Task 10.2 + 10.3)
--
-- WHAT DUAL-WRITE MEANS HERE
--
-- Today, `remittance_operations.status` is kept in sync with
-- `deals.stage_id` ONLY through the legacy bridge trigger
-- (trg_sync_operacion_desde_deal / cerebro_sync_operacion_desde_deal,
-- 041 + 060): every `UPDATE deals SET stage_id = ...` these three
-- functions perform fires that trigger, which derives a status with
-- cerebro_estado_desde_etapa(NEW.stage_id) and mirrors it onto the
-- linked remittance_operations row. Slice 11 deletes that bridge.
--
-- This migration makes the three functions below write
-- `remittance_operations.status` DIRECTLY, at every site they already
-- write `deals.stage_id`, using the SAME `cerebro_estado_desde_etapa()`
-- the bridge uses today — so stage-to-status mapping still lives in
-- exactly one place, and only slice 11 will need to swap these stage
-- parameters for status values outright. Every existing
-- `UPDATE deals SET stage_id = ...` and `INSERT INTO deals` KEEPS
-- running exactly as before; the new `UPDATE remittance_operations`
-- statements are ADDED alongside them, not instead of them. That is the
-- whole of "dual-write" here: after this migration, both
-- `deals.stage_id` and `remittance_operations.status` are set by the
-- SAME function call, from the SAME stage value, instead of the second
-- one being a side effect of a trigger on the first.
--
-- WHY THE `deals` WRITE STAYS — this is NOT slice 11's cleanup
--
-- The panel still depends on `deals.stage_id` in ways this slice cannot
-- touch:
--   - crm_entregar_operacion (101, amended by 108) REFUSES to deliver an
--     operation unless the DEAL is also in "Lista para transferir":
--       IF v_status_before IS DISTINCT FROM 'ready_to_transfer'
--          OR v_stage IS DISTINCT FROM v_lista THEN
--            RAISE EXCEPTION 'operation is not ready to transfer' ...
--     A deal stuck at its old stage because we stopped writing it here
--     would make every operation these three functions touch
--     undeliverable, even though remittance_operations.status says
--     ready_to_transfer.
--   - `deals` carries the only notification triggers on this path:
--     `deals_stage_notify` / `notify_deal_stage_change()` (the client
--     WhatsApp notification on a stage move) and
--     `trg_notify_deal_incidencia` (038, the incident alert). Neither
--     trigger exists on `remittance_operations`. Dropping the `deals`
--     write here would silently stop both kinds of notification for
--     every deposit these functions process.
--
-- Removing the `deals` half of the write, once the panel and its
-- notifications no longer need it, is slice 11's job — not this one's.
--
-- THE THREE WRITE SITES CHANGED (measured against 109's bodies; see the
-- diff in this task's report for the exact confirmation that these are
-- the ONLY differences from 109)
--
--   cerebro_registrar_deposito — three sites, all deriving status from
--   `p_stage` (already possibly overridden to Incidencia by the
--   REFERENCIA IMPOSIBLE (087) guard, which runs before all three):
--     (a) the "movido" branch (an existing open deal with no deposit
--         yet gets this one) — `UPDATE deals ... WHERE id = v_ex`.
--     (b) the "sumado" branch (an existing open deal already carries a
--         partial deposit toward its target) — `UPDATE deals ...
--         WHERE id = v_suma`.
--     (c) the brand-new-deal branch — `INSERT INTO deals ... RETURNING
--         id INTO v_id`. This one relies on the 041/060 bridge trigger
--         having ALREADY created the remittance_operations row within
--         that same INSERT statement, before control returns to the
--         next line of this function — see "HOW THE INSERT PATH WAS
--         CONFIRMED" below. The function already does exactly this for
--         `service_type` a few lines below (the 079 recarga
--         correction); the new statement here follows that same,
--         already-proven-in-production shape.
--
--   cerebro_cruzar_deposito — one site, deriving status from `v_stage`
--   (the stage the cross-reference just decided on: p_stage_ok on a
--   verified match, p_stage_incidencia otherwise) — the single
--   `UPDATE deals ... WHERE id = p_deal`, guarded by `IF NOT p_simular`
--   exactly like the deals write it sits next to.
--
--   cerebro_cruzar_depositos — one site, deriving status from
--   `v_stage_final` (the burst's own landing-stage decision — NOT the
--   same value cerebro_cruzar_deposito used internally per item, which
--   this function always calls with p_stage_ok = p_stage_incidencia =
--   p_stage_esperado during its dry run and real pass; the actual
--   transition only happens here) — the single `UPDATE deals ...
--   WHERE id = p_deal` in step (5), also guarded by `IF NOT p_simular`.
--
-- HOW THE INSERT PATH WAS CONFIRMED
--
-- Confirmed by reading, not by a dynamic test (see below for why a
-- dynamic test of this specific site is not possible): 041 and 060 both
-- define trg_sync_operacion_desde_deal as
--   AFTER INSERT OR DELETE OR UPDATE OF stage_id, value, contact_id,
--   currency ON deals FOR EACH ROW EXECUTE FUNCTION
--   cerebro_sync_operacion_desde_deal();
-- An AFTER ROW trigger fires once its row has been inserted, before the
-- firing statement returns control to its caller. For a single-row
-- `INSERT ... RETURNING id INTO v_id` issued from inside a PL/pgSQL
-- function, that means the trigger — and the remittance_operations
-- INSERT it performs — has already completed by the time execution
-- reaches the line after the INSERT. This is not a new assumption: the
-- existing `IF v_recarga THEN UPDATE remittance_operations SET
-- service_type = 'recarga' WHERE ro.deal_id = v_id; END IF;` a few
-- lines below the INSERT already depends on exactly this, and that
-- statement has been running in production since 079.
--
-- WHY live-baseline-parity.sql's BASELINE MOVES FOR THESE THREE
--
-- supabase/staging/assertions/live-baseline-parity.sql hashes these
-- seven functions' pg_get_functiondef() output and asserts it is
-- unchanged after applying a migration. Run it across 109 alone, and
-- (correctly) all seven still match: 109 changed nothing. Run it again
-- across 110, and cerebro_registrar_deposito, cerebro_cruzar_deposito
-- and cerebro_cruzar_depositos will now report FAIL — 110 deliberately
-- changed their bodies, that is the entire point of this migration. The
-- other four (cerebro_saldo_envio, cerebro_objetivo_atar,
-- cerebro_objetivo_cerrar, cerebro_es_revendedor) are untouched and
-- must still report PASS. From this migration forward, 110 — not 109 —
-- is the byte-identical baseline for these three functions; a future
-- migration touching them should diff against 110's bodies, not 109's.
--
-- PRIVILEGES — `CREATE OR REPLACE FUNCTION` preserves the ACL of an
-- existing function, so this changes nothing on staging or production.
-- A from-scratch database needs the REVOKE/GRANT restated (same
-- reasoning as 109's own PRIVILEGES section); repeated below for the
-- three functions this migration replaces.
--
-- ROLLBACK: see ROLLBACK-110-n8n-fn-repoint.sql, which restores 109's
-- three bodies verbatim.
-- =====================================================================

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

  -- La nota SIEMPRE lleva el comp_id, lo pusiera o no quien llama.
  v_nota := COALESCE(p_nota,'');
  IF NULLIF(p_comp_id,'') IS NOT NULL AND v_nota NOT LIKE '%'||p_comp_id||'%' THEN
    v_nota := v_nota || chr(10) || p_comp_id;
  END IF;

  -- REFERENCIA IMPOSIBLE (087). El TransID de MMG solo crece: por debajo del
  -- suelo historico no puede existir. El 13-ago la vision saco 10319372234891
  -- de una captura de otro chat que contenia la foto de un comprobante, y de
  -- paso invento el importe. Aqui no se valida que el deposito exista —eso es
  -- el cruce contra el libro—, solo que el numero PUEDA ser un TransID.
  IF NOT cerebro_transid_plausible(NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '')) THEN
    p_stage := 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid;
    v_nota := v_nota || chr(10)
      || 'REFERENCIA IMPOSIBLE: ese numero no puede ser un TransID de MMG. El contador '
      || 'solo crece y este queda por debajo de todos los recibidos, asi que casi seguro '
      || 'lo leyo la vision de una CAPTURA o de una foto de otra pantalla, no de un '
      || 'comprobante directo. NO se ha registrado como deposito normal: mire la imagen y '
      || 'pidale al cliente el comprobante original antes de dar nada por recibido.';
  END IF;

  -- (a) Idempotencia.
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

  -- (b) Envio abierto SIN deposito al que engancharlo.
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

  -- (b2) (073): envio abierto CON deposito pero INCOMPLETO.
  -- SOLO en "Por verificar": un envio en "Lista para transferir" ya esta
  -- cubierto y a punto de pagarse, y meterle dinero ahi seria otra cosa.
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
    -- (110) Direct write: this is the same UPDATE deals used to write
    -- stage_id, dual-written onto remittance_operations so the deal's
    -- mirror is right even once slice 11 removes the bridge trigger.
    -- Aliased `ro`, matching the existing service_type UPDATE below:
    -- `deal_id` unqualified is ambiguous here against this function's own
    -- `deal_id` OUT parameter (RETURNS TABLE(deal_id uuid, ...)).
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage)
     WHERE ro.deal_id = v_ex;
    PERFORM cerebro_objetivo_atar(p_conv, v_ex);
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  IF v_suma IS NOT NULL THEN
    -- value se SUMA, no se reemplaza: el deal vale lo depositado en total.
    UPDATE deals
       SET stage_id = p_stage,
           value    = COALESCE(value, 0) + p_monto,
           currency = p_moneda,
           notes    = COALESCE(notes,'') || E'\n---\n' || v_nota,
           updated_at = now()
     WHERE id = v_suma;
    -- (110) Direct write: same reasoning as the "movido" branch above,
    -- same `ro` alias for the same deal_id-ambiguity reason.
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage)
     WHERE ro.deal_id = v_suma;
    PERFORM cerebro_objetivo_atar(p_conv, v_suma);
    RETURN QUERY SELECT v_suma, 'sumado al envio abierto'::text, false, true; RETURN;
  END IF;

  -- (c) Envio nuevo.
  -- (079) ¿La conversacion en curso es una RECARGA? El cliente escribio
  -- recarga/etecsa/cubacel despues de su ultimo envio cerrado (tope 24 h) y
  -- NO ha dado ninguna tarjeta (tarjeta = remesa). La misma deteccion vive en
  -- el nodo `Contexto conversacion` (recarga_en_curso): cambiar una es
  -- cambiar la otra.
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

  -- (079) La operacion de la escritura dual nace como 'remesa'; si esto es
  -- una recarga, se corrige aqui mismo, dentro de la misma transaccion.
  IF v_recarga THEN
    UPDATE remittance_operations ro
       SET service_type = 'recarga'
     WHERE ro.deal_id = v_id;
  END IF;

  -- (110) Direct write: remittance_operations already exists at this
  -- point because the 041/060 dual-write trigger created it within the
  -- INSERT above (AFTER ROW trigger, same statement) — see this
  -- migration's header, "HOW THE INSERT PATH WAS CONFIRMED". Mirrors
  -- the service_type correction immediately above, same `ro` alias.
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
     AND d.anulado_en IS NULL                                   -- (1) anulados fuera
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
       AND m.anulado_en IS NULL                                 -- (2) anulados fuera
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
                    AND x.anulado_en IS NULL                     -- (3) anulados fuera
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
      -- (110) Direct write: same reasoning as cerebro_registrar_deposito
      -- above — dual-write remittance_operations.status alongside the
      -- deals.stage_id write this cross-reference just decided on.
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

  -- (0) SIN OBJETIVO y con un solo comprobante: la de siempre, sin tocar nada.
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

  -- (1) GUARDAS DE LA RAFAGA.
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

  -- (2) PASADA EN SECO.
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

  -- (3) PASADA DE VERDAD, solo si la seca dijo que cruzan TODOS.
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

  -- (4) EL SALDO MANDA. Se relee DESPUES de consumir.
  SELECT s.objetivo, s.depositado, s.saldo INTO v_obj, v_dep, v_saldo
    FROM cerebro_saldo_envio(p_deal) s;
  IF p_simular AND v_obj IS NOT NULL THEN
    -- En seco no se consumio nada, asi que se simula el saldo que quedaria.
    v_dep := v_dep + CASE WHEN v_todos THEN v_total ELSE 0 END;
    v_saldo := v_obj - v_dep;
  END IF;

  v_stage_final := CASE
    WHEN NOT v_todos           THEN p_stage_incidencia
    WHEN v_saldo IS NULL       THEN p_stage_ok          -- sin objetivo: como siempre
    WHEN v_saldo > 0           THEN p_stage_esperado    -- falta dinero: esperando
    WHEN v_saldo < 0           THEN p_stage_incidencia  -- se paso: lo mira una persona
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
    -- (110) Direct write: dual-write remittance_operations.status from
    -- v_stage_final — this function's OWN landing-stage decision, taken
    -- after the whole burst is consumed, distinct from the per-item
    -- stage cerebro_cruzar_deposito used internally above (see this
    -- migration's header).
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

-- =====================================================================
-- PRIVILEGES — see 109's own PRIVILEGES section for the full reasoning.
-- `CREATE OR REPLACE FUNCTION` above preserves the ACL these three
-- functions already carry on staging/production; this exists only so a
-- from-scratch database ends up with the same hardened ACL
-- (`{postgres=X/postgres,service_role=X/postgres}`) instead of the
-- Postgres default of PUBLIC EXECUTE.
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

NOTIFY pgrst, 'reload schema';
