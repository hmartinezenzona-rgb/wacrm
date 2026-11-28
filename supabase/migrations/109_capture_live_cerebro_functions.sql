-- =====================================================================
-- 109 — Capture the live, unversioned cerebro_* functions as a baseline
--
-- Seven `cerebro_*` functions that n8n calls run live on staging and
-- production but have NO versioned definition anywhere in this repo's
-- migration history: they were created directly on the database (or, in
-- the case of cerebro_registrar_deposito, mutated in place by 087 — see
-- below) rather than through a migration file. Slice 10 needs to repoint
-- these functions and cannot safely do that while the repo has no source
-- of truth for what they currently do.
--
-- This migration changes NO behavior. Every body below is copied
-- byte-for-byte from `pg_get_functiondef()` as observed live on staging
-- (verified against production semantics by the migration history that
-- reaches these functions — 079, 087, 096, 099). Applied to any
-- environment that already has these seven functions (staging,
-- production), `CREATE OR REPLACE FUNCTION` with an identical body is a
-- byte-identical no-op: it neither changes behavior nor drops privileges
-- (see PRIVILEGES below). Its only purpose is to give this repository — and
-- a freshly-built database — a real, versioned starting point that slice
-- 10 can then modify with an ordinary migration.
--
-- The function bodies themselves contain Spanish comments, written by
-- whoever authored them in production over time. They are left
-- byte-for-byte untouched here; only this surrounding migration and its
-- own comments are in English.
--
-- ---------------------------------------------------------------------
-- THE 087 WARNING — READ THIS BEFORE TOUCHING cerebro_registrar_deposito
-- ---------------------------------------------------------------------
--
-- `087_referencia_imposible_no_se_registra.sql` (lines 65-98) does NOT
-- `CREATE OR REPLACE FUNCTION cerebro_registrar_deposito`. It TEXT-PATCHES
-- the function's live body at deploy time: it reads the current body with
-- `pg_get_functiondef()`, calls `replace()` on it looking for the literal
-- anchor line `  -- (a) Idempotencia.`, and splices in the "REFERENCIA
-- IMPOSIBLE" anti-fraud block (the TransID-plausibility guard) immediately
-- before that anchor. If the anchor is missing, or if the replace() ends up
-- being a no-op, 087 RAISEs and refuses to apply. The resulting text is
-- then run with a dynamic `EXECUTE`, never written out as static SQL in
-- the migration file.
--
-- Two consequences that matter for anyone working on this function:
--
--   (a) The body captured below ALREADY CONTAINS 087's injected block
--       (search for "REFERENCIA IMPOSIBLE (087)" in the body). 087 must
--       NEVER be re-run against an environment where this migration (109)
--       has already applied — its anchor-replace would fire a second time
--       and inject the block twice. 087 is already marked
--       "YA APLICADA EN PRODUCCION... NO LA EJECUTES" for exactly this
--       kind of reason; this migration does not change that, it just adds
--       a second, independent reason never to replay it.
--
--   (b) `grep "CREATE OR REPLACE FUNCTION cerebro_registrar_deposito"` over
--       the pre-109 migration history finds only 079. That is misleading:
--       079 is the function's ORIGINAL body, before 087 patched it. The
--       live body — the one actually running on staging and production,
--       and the one captured verbatim below — is 079's body PLUS 087's
--       injected block. Anyone reading 079 alone is reading a version of
--       this function that has not existed live since 087 was applied.
--
-- ---------------------------------------------------------------------
-- PRIVILEGES — see the PRIVILEGES section near the end of this file for
-- why REVOKE/GRANT statements are required here even though this is a
-- byte-identical capture.
-- ---------------------------------------------------------------------

-- cerebro_registrar_deposito — originally created by 079 (recarga
-- distinguida de remesa); its body was then text-patched in place by 087
-- (REFERENCIA IMPOSIBLE guard — see the 087 WARNING above). The body below
-- is 079 + 087's injection, captured verbatim from the live function.
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

  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

-- cerebro_cruzar_deposito — the single-deposit cross-reference engine
-- against the MMG deposits book. No repo origin: never versioned before
-- this migration. Referenced (but not defined) by 099's comment as "LIVE
-- on staging and production but NOT versioned in this repository's
-- migrations". First versioned here.
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

-- cerebro_cruzar_depositos — the multi-deposit (burst) cross-reference
-- wrapper around cerebro_cruzar_deposito, used when a single remittance is
-- covered by more than one deposit receipt. No repo origin: never
-- versioned before this migration. First versioned here.
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

-- cerebro_saldo_envio — reads a deal's remittance target vs. what has been
-- deposited and consumed against it so far. No repo origin: never
-- versioned before this migration. First versioned here.
CREATE OR REPLACE FUNCTION public.cerebro_saldo_envio(p_deal uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH dep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.deal_id = p_deal
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
  ),
  obj AS (
    SELECT o.monto, o.moneda
      FROM cerebro_objetivo_envio o
      JOIN deals d ON d.conversation_id = o.conversation_id
     WHERE d.id = p_deal
       AND o.cerrado_en IS NULL
       AND (o.deal_id IS NULL OR o.deal_id = p_deal)
  )
  SELECT (SELECT monto FROM obj),
         (SELECT total FROM dep),
         (SELECT monto FROM obj) - (SELECT total FROM dep),
         COALESCE((SELECT moneda FROM obj), 'GYD');
$function$;

-- cerebro_objetivo_atar — attaches an open remittance target
-- (cerebro_objetivo_envio) to the deal it belongs to. No repo origin:
-- never versioned before this migration. First versioned here.
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_atar(p_conv uuid, p_deal uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  UPDATE cerebro_objetivo_envio
     SET deal_id = p_deal
   WHERE conversation_id = p_conv AND cerrado_en IS NULL AND deal_id IS NULL;
$function$;

-- cerebro_objetivo_cerrar — closes a remittance target once its balance is
-- settled. No repo origin: never versioned before this migration. First
-- versioned here.
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_cerrar(p_deal uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  UPDATE cerebro_objetivo_envio
     SET cerrado_en = now()
   WHERE deal_id = p_deal AND cerrado_en IS NULL;
$function$;

-- cerebro_es_revendedor — whether a conversation's contact is an active
-- reseller (cerebro_revendedores). No repo origin: never versioned before
-- this migration. First versioned here.
CREATE OR REPLACE FUNCTION public.cerebro_es_revendedor(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM conversations v
      JOIN contacts c ON c.id = v.contact_id
      JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
     WHERE v.id = p_conv);
$function$;

-- =====================================================================
-- PRIVILEGES
--
-- `pg_get_functiondef()` — the source of every body above — does NOT
-- include GRANT/REVOKE: privileges are not part of a function's
-- definition, they are separate ACL entries on the pg_proc row.
-- `CREATE OR REPLACE FUNCTION` preserves the existing privileges of a
-- function it replaces, so applying this migration to staging or
-- production changes nothing there. But on a FRESH database built from
-- this migration history from scratch, these seven would otherwise be
-- created with the Postgres default — EXECUTE granted to PUBLIC — because
-- no earlier migration in a from-scratch build has created them yet for
-- 064's `ALTER DEFAULT PRIVILEGES` (which only covers objects created
-- AFTER it ran) to apply to. That would silently reopen exactly the hole
-- 064_revoke_rpc_publicas.sql and 089_anon_no_ejecuta_funciones_del_cerebro.sql
-- close for every other `cerebro_*` function.
--
-- The privileges below are not assumed: they are the ACTUAL ACL observed
-- live on staging (see this task's report for the raw `proacl` query and
-- output). All seven currently carry the identical, already-hardened ACL
-- `{postgres=X/postgres,service_role=X/postgres}` — i.e. only the owner
-- and service_role can execute them; PUBLIC, anon and authenticated have
-- nothing. Three of the seven (cerebro_registrar_deposito,
-- cerebro_cruzar_deposito, cerebro_es_revendedor) reach that state via
-- 064's explicit REVOKE/GRANT block; the other four reach the same state
-- without ever being listed in a migration, almost certainly because they
-- were created after 064's `ALTER DEFAULT PRIVILEGES IN SCHEMA public
-- REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC/anon/authenticated` took effect.
-- Either way, the statements below simply reproduce that observed ACL
-- explicitly, so a from-scratch build ends up in the same state as
-- staging/production regardless of migration order or default-privilege
-- timing.
REVOKE EXECUTE ON FUNCTION
  cerebro_cruzar_deposito(uuid,text,numeric,uuid,uuid,uuid,boolean),
  cerebro_cruzar_depositos(uuid,text[],numeric[],uuid,uuid,uuid,boolean),
  cerebro_es_revendedor(uuid),
  cerebro_objetivo_atar(uuid,uuid),
  cerebro_objetivo_cerrar(uuid),
  cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text),
  cerebro_saldo_envio(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  cerebro_cruzar_deposito(uuid,text,numeric,uuid,uuid,uuid,boolean),
  cerebro_cruzar_depositos(uuid,text[],numeric[],uuid,uuid,uuid,boolean),
  cerebro_es_revendedor(uuid),
  cerebro_objetivo_atar(uuid,uuid),
  cerebro_objetivo_cerrar(uuid),
  cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text),
  cerebro_saldo_envio(uuid)
TO service_role;

NOTIFY pgrst, 'reload schema';
