-- =====================================================================
-- 144 — crm_verificar_deposito silently refuses a genuinely-pending
--        deposit for any operation whose deal existed before its deposit
--
-- PROBLEM (B3.3, production feedback 2026-09-29): "Some remesas verified
-- and delivered from the right panel still show [a not-ready status]."
--
-- ROOT CAUSE: cerebro_cruzar_deposito (114) still gates on
--   (SELECT stage_id FROM deals WHERE id = p_deal) = p_stage_esperado
-- ("v_aplica") to decide whether this cross-reference attempt still
-- applies — a staleness guard inherited unchanged from the pre-114 world,
-- where deals.stage_id WAS the authoritative, live-updated column. 114
-- made remittance_operations.status the sole authoritative column and
-- stopped writing deals.stage_id from every one of this repo's write
-- paths (section 3-6 of 114's own header: "a deal is now 'born' at some
-- initial stage and stays there historically"), but left this ONE read
-- site unchanged — the exact same class of oversight 125 already found
-- and fixed once for a WRITE path (deal INSERT).
--
-- The result: deals.stage_id now permanently reflects the deal's BIRTH
-- stage. For a deal that already existed before its deposit arrived
-- (`cerebro_registrar_deposito`'s "movido"/"sumado" branches — the same
-- ~13% of deals 125 measured, e.g. a customer who gives the beneficiary
-- before depositing), the deal is born at "Solicitada" and its
-- OPERATION's status later advances to 'deposit_verification' via a
-- direct, deals.stage_id-untouched UPDATE. `deals.stage_id` never
-- catches up. When the operator then clicks "Verify" in the panel,
-- `crm_verificar_deposito` derives `p_stage_esperado` from the
-- operation's CURRENT status ('deposit_verification' -> "Por
-- verificar"), but `deals.stage_id` is still "Solicitada" — so
-- `v_aplica` is false, `cerebro_cruzar_deposito` returns
-- `resultado: 'no_aplica'` ("The operation is not awaiting
-- verification") without even looking at the ref/amount, and the
-- operation's status never advances. This is a normal 200 OK response,
-- not a thrown error, so it is easy to read as "nothing happened" or
-- mis-describe later — exactly what B3.3 reports. The SAME shared
-- function backs n8n's automatic MMG cross-reference, so the automatic
-- path is equally silently defeated for these operations; only the
-- admin-only `crm_forzar_verificacion` escape hatch (which never reads
-- deals.stage_id) still works for them.
--
-- FIX: `v_aplica` now compares against the authoritative column —
-- `remittance_operations.status` (via `p_deal`'s `deal_id`), mapped back
-- to a status string with the SAME `cerebro_estado_desde_etapa` every
-- other call site already uses to translate a stage id — instead of the
-- no-longer-maintained `deals.stage_id`. This is the exact staleness
-- check the pre-114 code intended ("has this deal moved since I looked
-- at it?"), just pointed at the column that's actually kept current.
-- Every other line of `cerebro_cruzar_deposito` is untouched, verbatim
-- from 114.
--
-- `cerebro_cruzar_depositos` needs no change of its own: both its
-- early-return (v_n <= 1, no objetivo) and its multi-deposit loop
-- delegate every actual cross-reference attempt to this same
-- `cerebro_cruzar_deposito`, so fixing it here fixes both callers.
--
-- Guarded by supabase/staging/assertions/verify-deposit-status-drift.sql
-- (RED against 114-143, GREEN once this migration is applied).
--
-- ROLLBACK: ROLLBACK-144-verify-deposit-status-drift.sql
-- =====================================================================

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

  -- (144) Was: compared against deals.stage_id, a column nothing has
  -- written since 114 for an operation whose status advanced through
  -- the "movido"/"sumado" branches of cerebro_registrar_deposito (or the
  -- panel RPCs) — see this file's header. remittance_operations.status
  -- is the authoritative, live-updated column post-114; a NULL deal_id
  -- (no linked operation) coalesces to false, same fail-closed posture
  -- the old check had for a deal with no row at all.
  SELECT COALESCE(
           (SELECT ro.status FROM remittance_operations ro WHERE ro.deal_id = p_deal)
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
         SET notes = COALESCE(notes,'') || chr(10) || v_nota,
             updated_at = now()
       WHERE id = p_deal;
      GET DIAGNOSTICS v_tocados = ROW_COUNT;
      -- (114) deals.stage_id is no longer written here. Status is set
      -- directly, as it already was since 110.
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

-- =====================================================================
-- VALIDATE ON STAGING before this repo's migrations are considered
-- fully applied there — see
-- supabase/staging/assertions/verify-deposit-status-drift.sql (RED/GREEN
-- discipline: run it first against 114-143 to see it fail, then again
-- after this migration to see it pass).
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-144-verify-deposit-status-drift.sql
-- =====================================================================
