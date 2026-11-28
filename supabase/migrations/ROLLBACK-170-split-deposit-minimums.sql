-- ROLLBACK for 170: restores the production registrar (125's body, prosrc md5 a0251d99...)
-- and 168's single-receipt late job, then drops 170's functions and config keys.
-- Objetivos already written stay; they close by themselves when their deal is verified.

CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito(p_conv uuid, p_monto numeric, p_moneda text, p_stage uuid, p_nota text, p_comp_id text)
 RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
-- (114) The creado path's `ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL`
-- collides with this function's `deal_id` OUT parameter and raised
-- `column reference "deal_id" is ambiguous` on every new receipt (staging
-- smoke 2026-09-26). use_column only affects references that were
-- ambiguous, i.e. that raised; every other reference resolves as before.
-- Guarded by supabase/staging/assertions/registrar-deposito-creado.sql.
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
  v_contact uuid;
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
       SET value = p_monto, currency = p_moneda,
           notes = COALESCE(notes,'') || E'\n---\n' || v_nota, updated_at = now()
     WHERE id = v_ex
    RETURNING contact_id INTO v_contact;
    -- (114) Direct, self-sufficient write: replaces both halves of the
    -- retired bridge trigger for this branch (status derivation AND
    -- quoted_source_amount/contact_id mirroring). `deals.stage_id` is no
    -- longer written by this function; `p_stage` still decides the
    -- operation's status.
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           quoted_source_amount = p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.deal_id = v_ex;
    PERFORM cerebro_objetivo_atar(p_conv, v_ex);
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  IF v_suma IS NOT NULL THEN
    UPDATE deals
       SET value    = COALESCE(value, 0) + p_monto,
           currency = p_moneda,
           notes    = COALESCE(notes,'') || E'\n---\n' || v_nota,
           updated_at = now()
     WHERE id = v_suma
    RETURNING contact_id, value INTO v_contact, p_monto;
    -- (114) Same reasoning as the "movido" branch. `p_monto` was just
    -- reassigned by the RETURNING above to the SUMMED value on purpose —
    -- quoted_source_amount must reflect the total, not the increment.
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           quoted_source_amount = p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
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

  SELECT c.phone, v.contact_id INTO v_phone, v_contact
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

  -- (114) Explicit creation, replacing the row-creation half of the
  -- retired bridge trigger. Same columns/values that trigger's INSERT
  -- branch used (041/043/060): status derived from p_stage,
  -- completed_at/cancelled_at seeded consistently even though p_stage
  -- is never Entregada/cancelled-mapped from this call site in practice
  -- (kept for parity with the mapping function's full range).
  INSERT INTO remittance_operations (
    account_id, conversation_id, contact_id, deal_id, status,
    service_type, quoted_source_amount, source_currency, created_at,
    completed_at, cancelled_at
  )
  SELECT v.account_id, v.id, v_contact, v_id,
         cerebro_estado_desde_etapa(p_stage),
         CASE WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
         p_monto, coalesce(p_moneda, 'GYD'), now(),
         CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'completed' THEN now() END,
         CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'cancelled' THEN now() END
    FROM conversations v WHERE v.id = p_conv
  -- (125) The deal INSERT above now creates this row through
  -- trg_sync_operacion_al_crear_deal, always as 'remesa'. Keep the recarga
  -- classification this function decides: only service_type is corrected,
  -- and only when it differs, so a plain remesa writes nothing twice.
  ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO UPDATE
    SET service_type = EXCLUDED.service_type
    WHERE remittance_operations.service_type IS DISTINCT FROM EXCLUDED.service_type;

  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_recruzar_depositos_tardios()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_ok       CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';  -- ready_to_transfer
  c_esperado CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';  -- deposit_verification
  v_op   record;
  v_sim  record;
  v_real record;
  v_n    integer := 0;
BEGIN
  FOR v_op IN
    SELECT o.id, o.account_id, o.deal_id, x.ref, x.monto
      FROM remittance_operations o
      JOIN deals d ON d.id = o.deal_id
      CROSS JOIN LATERAL (
        SELECT (regexp_match(d.notes, 'Ref: ([0-9]{8,})'))[1] AS ref,
               replace((regexp_match(d.notes, 'DEPOSITO: ([0-9][0-9,]*)'))[1], ',', '')::numeric AS monto,
               (SELECT count(*) FROM regexp_matches(d.notes, 'Ref: [0-9]{8,}', 'g')) AS n_refs,
               (SELECT count(*) FROM regexp_matches(d.notes, 'DEPOSITO: [0-9]', 'g')) AS n_dep
      ) x
     WHERE o.status = 'deposit_verification'
       AND o.service_type = 'remesa'
       AND o.created_at > now() - interval '24 hours'
       AND o.updated_at < now() - interval '90 seconds'
       AND x.n_refs = 1 AND x.n_dep = 1
       AND EXISTS (SELECT 1 FROM depositos_mmg m
                    WHERE m.trans_id = x.ref AND m.consumido_en IS NULL AND m.anulado_en IS NULL)
     FOR UPDATE OF o SKIP LOCKED
  LOOP
    SELECT * INTO v_sim FROM cerebro_cruzar_depositos(v_op.deal_id, ARRAY[v_op.ref], ARRAY[v_op.monto],
                                                       c_ok, c_esperado, c_esperado, true);
    CONTINUE WHEN v_sim.resultado NOT IN ('verificado', 'verificado_incompleto');

    SELECT * INTO v_real FROM cerebro_cruzar_depositos(v_op.deal_id, ARRAY[v_op.ref], ARRAY[v_op.monto],
                                                        c_ok, c_esperado, c_esperado, false);
    CONTINUE WHEN v_real.resultado NOT IN ('verificado', 'verificado_incompleto');

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'status', 'automation_late_deposit_verification', NULL,
            'MMG email ingested after the receipt was processed; re-crossed by cerebro_recruzar_depositos_tardios.',
            jsonb_build_object('status', 'deposit_verification'),
            jsonb_build_object('resultado', v_real.resultado, 'trans_id', v_real.trans_id,
                               'status', (SELECT status FROM remittance_operations WHERE id = v_op.id)));
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

DROP FUNCTION IF EXISTS public.cerebro_cruzar_pendientes(uuid, text);
DROP FUNCTION IF EXISTS public.cerebro_objetivo_minimo(uuid, uuid, boolean);
DROP FUNCTION IF EXISTS public.cerebro_minimo_gyd(uuid);
DELETE FROM cerebro_config WHERE clave IN ('minimo_gyd_cup','minimo_gyd_usd','minimo_gyd_efectivo_usd','minimo_gyd_recarga','minimo_gyd_tramite','completar_ventana_horas');
