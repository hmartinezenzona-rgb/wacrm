-- =====================================================================
-- 197 — A misread receipt reference still finds its MMG email (staging first)
--
-- odd/tasks/vision-document-catalog.md (V0). Production 28-sep..2-oct: of 50 receipts read by vision, 46 matched their
-- MMG email exactly; 3 had a misread reference (one digit 5->3; two neighbours swapped 78<->87; a badly read photo of a
-- monitor). Each needed a forced verification by hand and its real email stayed unconsumed. Two gaps:
--   - cerebro_cruzar_deposito's approximate match demanded the same length and the same first 5 and last 4 digits:
--     a swap at the end escaped it;
--   - the late re-cross (cerebro_recruzar_depositos_tardios -> cerebro_cruzar_pendientes) only took EXACT references,
--     so an email ingested seconds after the photo was never paired with a one-digit-off reading.
-- cerebro_ref_parecida(read, real): 8+ digits, lengths +-1, optimal string alignment distance <= 2 (a swap of
-- neighbours counts 1). The approximate match keeps every other guard (same amount, unconsumed, not voided, inside the
-- window, ONE candidate) and keeps alerting the admin (CRUCE_APROXIMADO) to check the receipt; the late re-cross now
-- also considers a similar reference of the same amount. Exact matching is unchanged.
--
-- Guarded by supabase/staging/assertions/cruce-ref-parecida.sql.
-- ROLLBACK: ROLLBACK-197-cruce-ref-parecida.sql
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cerebro_ref_parecida(p_leida text, p_real text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
-- Optimal string alignment distance (substitution, insertion, deletion, swap of neighbours = 1 each) <= 2, between
-- two all-digit references of 8+ digits whose lengths differ by at most 1.
DECLARE
  a text := regexp_replace(coalesce(p_leida, ''), '[^0-9]', '', 'g');
  b text := regexp_replace(coalesce(p_real, ''), '[^0-9]', '', 'g');
  la int; lb int; i int; j int; cost int;
  d int[][];
BEGIN
  la := length(a); lb := length(b);
  IF la < 8 OR lb < 8 OR abs(la - lb) > 1 THEN RETURN false; END IF;
  IF a = b THEN RETURN true; END IF;
  d := array_fill(0, ARRAY[la + 1, lb + 1]);
  FOR i IN 0 .. la LOOP d[i + 1][1] := i; END LOOP;
  FOR j IN 0 .. lb LOOP d[1][j + 1] := j; END LOOP;
  FOR i IN 1 .. la LOOP
    FOR j IN 1 .. lb LOOP
      cost := CASE WHEN substr(a, i, 1) = substr(b, j, 1) THEN 0 ELSE 1 END;
      d[i + 1][j + 1] := least(d[i][j + 1] + 1, d[i + 1][j] + 1, d[i][j] + cost);
      IF i > 1 AND j > 1 AND substr(a, i, 1) = substr(b, j - 1, 1) AND substr(a, i - 1, 1) = substr(b, j, 1) THEN
        d[i + 1][j + 1] := least(d[i + 1][j + 1], d[i - 1][j - 1] + 1);
      END IF;
    END LOOP;
  END LOOP;
  RETURN d[la + 1][lb + 1] <= 2;
END $function$;
REVOKE ALL ON FUNCTION public.cerebro_ref_parecida(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_ref_parecida(text, text) TO service_role;

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
  v_op_id      uuid;
BEGIN
  -- (160) Resolve either flavour of id to an operation id.
  v_op_id := cerebro_resolve_op_id(p_deal);

  v_ref := NULLIF(regexp_replace(COALESCE(p_ref, ''), '[^0-9]', '', 'g'), '');

  SELECT COALESCE(
           (SELECT ro.status FROM remittance_operations ro WHERE ro.id = v_op_id)
             = cerebro_estado_desde_etapa(p_stage_esperado),
           false)
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
      -- (160) Compatibility shim: mirror the legacy deal_id onto
      -- depositos_mmg so the 159 reader's WHERE deal_id = v_deal_id
      -- query continues to resolve consumed deposits. When the
      -- resolved operation has deal_id IS NULL we leave it untouched.
      UPDATE depositos_mmg d
         SET consumido_en = now(), operation_id = v_op_id,
             deal_id = COALESCE(deal_id, (SELECT deal_id FROM remittance_operations WHERE id = v_op_id))
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
       -- (197) was: same length, first 5 and last 4 digits
       AND cerebro_ref_parecida(v_ref, m.trans_id);

    IF v_candidatos = 1 THEN
      IF p_simular THEN
        SELECT m.trans_id INTO v_trans
          FROM depositos_mmg m
         WHERE m.consumido_en IS NULL AND m.anulado_en IS NULL AND m.monto = p_monto
           AND m.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                                 AND now() + interval '15 minutes'
           -- (197) was: same length, first 5 and last 4 digits
       AND cerebro_ref_parecida(v_ref, m.trans_id);
      ELSE
        UPDATE depositos_mmg m
           SET consumido_en = now(), operation_id = v_op_id,
               deal_id = COALESCE(deal_id, (SELECT deal_id FROM remittance_operations WHERE id = v_op_id))
         WHERE m.trans_id = (
                 SELECT x.trans_id FROM depositos_mmg x
                  WHERE x.consumido_en IS NULL
                    AND x.anulado_en IS NULL
                    AND x.monto = p_monto
                    AND x.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                                          AND now() + interval '15 minutes'
                    -- (197) was: same length, first 5 and last 4 digits
       AND cerebro_ref_parecida(v_ref, x.trans_id)
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
        'VERIFICADO: casa con el correo de MMG (TransID ' || v_trans || ') '
        || '- COINCIDENCIA APROXIMADA: el comprobante decia ' || v_ref
        || '. Coinciden importe y hora, la referencia difiere en 2 digitos o menos, y era el unico'
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
      -- (160) Compatibility shim: write deal_id on depositos_mmg so the
      -- 159 reader's WHERE deal_id = v_deal_id still resolves consumed
      -- deposits for legacy operations.
      UPDATE remittance_operations
         SET status = cerebro_estado_desde_etapa(v_stage),
             incident_reason = CASE WHEN cerebro_estado_desde_etapa(v_stage) = 'incident'
                                    THEN v_nota ELSE NULL END,
             updated_at = now()
       WHERE id = v_op_id;
      GET DIAGNOSTICS v_tocados = ROW_COUNT;
    ELSE
      v_tocados := 1;
    END IF;
  END IF;

  IF NOT p_simular AND v_metodo IN ('aproximado','ambiguo') THEN
    SELECT o.conversation_id INTO v_conv FROM remittance_operations o WHERE o.id = v_op_id;
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

CREATE OR REPLACE FUNCTION public.cerebro_cruzar_pendientes(p_deal uuid, p_excepto text DEFAULT NULL::text)
 RETURNS TABLE(resultado text, trans_id text, n_refs integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_ok       CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  c_esperado CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_op    uuid := cerebro_resolve_op_id(p_deal);
  v_refs  text[];
  v_mont  numeric[];
  v_sim   record;
  v_real  record;
BEGIN
  SELECT array_agg(b.ref ORDER BY b.ord1, b.ord2), array_agg(b.monto ORDER BY b.ord1, b.ord2)
    INTO v_refs, v_mont
    FROM (SELECT DISTINCT ON ((regexp_match(r.reference, '([0-9]{8,})'))[1])
                 (regexp_match(r.reference, '([0-9]{8,})'))[1] AS ref, r.amount AS monto,
                 COALESCE(r.block_index, 0) AS ord1, r.created_at AS ord2
            FROM remittance_operation_receipts r
           WHERE r.operation_id = v_op AND r.amount IS NOT NULL
           ORDER BY (regexp_match(r.reference, '([0-9]{8,})'))[1], r.created_at) b
   WHERE b.ref IS NOT NULL
     AND b.ref IS DISTINCT FROM p_excepto
     AND EXISTS (SELECT 1 FROM depositos_mmg m
                  -- (197) or a similar reference of the same amount (a misread digit or a swap)
                  WHERE (m.trans_id = b.ref OR (m.monto = b.monto AND cerebro_ref_parecida(b.ref, m.trans_id)))
                    AND m.consumido_en IS NULL AND m.anulado_en IS NULL);

  IF v_refs IS NULL THEN RETURN; END IF;

  SELECT * INTO v_sim FROM cerebro_cruzar_depositos(v_op, v_refs, v_mont, c_ok, c_esperado, c_esperado, true);
  IF v_sim.resultado NOT IN ('verificado', 'verificado_incompleto') THEN
    RETURN QUERY SELECT v_sim.resultado, NULL::text, cardinality(v_refs); RETURN;
  END IF;
  SELECT * INTO v_real FROM cerebro_cruzar_depositos(v_op, v_refs, v_mont, c_ok, c_esperado, c_esperado, false);
  RETURN QUERY SELECT v_real.resultado, v_real.trans_id, cardinality(v_refs);
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_recruzar_depositos_tardios()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op  record;
  v_res record;
  v_n   integer := 0;
BEGIN
  FOR v_op IN
    SELECT o.id, o.account_id
      FROM remittance_operations o
     WHERE o.status = 'deposit_verification'
       AND o.service_type = 'remesa'
       AND o.created_at > now() - interval '24 hours'
       AND o.updated_at < now() - interval '90 seconds'
       AND EXISTS (SELECT 1 FROM depositos_mmg m JOIN remittance_operation_receipts r
                     ON r.operation_id = o.id
                    AND (r.reference ~ ('(^|[^0-9])' || m.trans_id || '([^0-9]|$)')
                         -- (197) or a similar reference of the same amount (a misread digit or a swap)
                         OR (m.monto = r.amount AND cerebro_ref_parecida((regexp_match(r.reference, '([0-9]{8,})'))[1], m.trans_id)))
                    WHERE m.consumido_en IS NULL AND m.anulado_en IS NULL)
     FOR UPDATE OF o SKIP LOCKED
  LOOP
    SELECT * INTO v_res FROM cerebro_cruzar_pendientes(v_op.id);
    CONTINUE WHEN v_res.resultado IS DISTINCT FROM 'verificado';

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'status', 'automation_late_deposit_verification', NULL,
            'MMG email ingested after the receipt was processed; re-crossed by cerebro_recruzar_depositos_tardios.',
            jsonb_build_object('status', 'deposit_verification'),
            jsonb_build_object('resultado', v_res.resultado, 'trans_id', v_res.trans_id, 'n_refs', v_res.n_refs,
                               'status', (SELECT status FROM remittance_operations WHERE id = v_op.id)));
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;
