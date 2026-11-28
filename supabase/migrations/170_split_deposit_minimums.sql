-- =====================================================================
-- 170 — split deposits: the service minimum is the remesa target
--
-- Real case (Yais 5927166900, 2026-09-28): a 50 USD Zelle (13,000 GYD) paid as
-- 3,000 + 10,000 became TWO operations — 3,000 in incident and 10,000
-- verified and promised "el equivalente". Production had never summed two
-- deposits: the sum branch needed an objetivo, which only the LLM sets (by
-- calling calcular_usd), and it still filtered on deals.stage_id, which
-- nothing writes since 114.
--
-- Business rule (user, 2026-10-01): a deposit below the minimum of the
-- service the customer chose is a part payment, not a remesa. Minimums in
-- GYD: CUP 5,000; Zelle / Clasica / Tropical 13,000; cash USD 29,000;
-- recargas 5,200 (6,200 for the higher promotion); visa extension and
-- translations 5,000. Kept in cerebro_config so they can change without code.
--
-- What changes:
--   1. cerebro_minimo_gyd(op): the minimum of the operation's rail, taken from
--      delivery_method, then the vigente beneficiary, then what the customer
--      said (157's pending destination, the partial beneficiary). Unknown rail
--      -> the smallest remesa minimum (CUP), so nothing is held by mistake.
--   2. cerebro_objetivo_minimo(conv, deal, total): an operation below its
--      minimum gets an objetivo of at least that minimum, so the cross
--      (cerebro_cruzar_depositos) leaves it WAITING ('verificado_incompleto')
--      instead of ready to transfer. A higher objetivo the customer already
--      set (a quote) is kept. Never touches another deal's open objetivo.
--   3. cerebro_registrar_deposito: the "sumado" branch now looks at the
--      OPERATION, not the stale deal stage. A new deposit joins the open
--      waiting operation of the conversation (deposit_verification or
--      incident, opened in the last completar_ventana_horas, not an
--      impossible reference) when that operation is below its minimum, still
--      owes saldo, or the new deposit alone is below the smallest minimum.
--      A ready_to_transfer operation is never changed. After joining, the
--      earlier receipts of that operation that were never crossed (Yais's
--      3,000, left in incident) are crossed now; the new receipt is crossed
--      by the Cerebro's own node right after, as always.
--   4. cerebro_cruzar_pendientes(deal, except_ref): crosses every receipt of
--      a deal whose MMG email is in the ledger and unconsumed, dry run first.
--      168's late job uses it, so multi-receipt operations are re-crossed too.
--
-- Guarded by supabase/staging/assertions/split-deposit-minimums.sql
-- ROLLBACK: ROLLBACK-170-split-deposit-minimums.sql
-- =====================================================================

INSERT INTO cerebro_config (clave, valor, descripcion) VALUES
  ('minimo_gyd_cup', '5000', 'Deposito minimo en GYD para una remesa a tarjeta CUP (170).'),
  ('minimo_gyd_usd', '13000', 'Deposito minimo en GYD para Zelle, Clasica, Tropical y Mexico (170).'),
  ('minimo_gyd_efectivo_usd', '29000', 'Deposito minimo en GYD para entrega de dolares en efectivo (170).'),
  ('minimo_gyd_recarga', '5200', 'Deposito minimo en GYD para una recarga (promocion de 500 CUP; la de 600 CUP son 6200) (170).'),
  ('minimo_gyd_tramite', '5000', 'Deposito minimo en GYD para extension de visa y traduccion por hoja (170).'),
  ('completar_ventana_horas', '6', 'Horas durante las que un deposito puede completar una remesa abierta del mismo chat (170).')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cerebro_minimo_gyd(p_op uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op   remittance_operations%ROWTYPE;
  v_riel text;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_op;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_op.service_type = 'recarga' THEN
    RETURN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200);
  END IF;

  v_riel := COALESCE(
    NULLIF(v_op.delivery_method, ''),
    (SELECT b.beneficiary_type FROM remittance_beneficiaries b
      WHERE b.operation_id = v_op.id AND b.status = 'vigente' ORDER BY b.position LIMIT 1),
    (SELECT p.tipo FROM cerebro_destino_pendiente p
      WHERE p.conversation_id = v_op.conversation_id AND p.actualizado > now() - interval '24 hours'),
    (SELECT CASE WHEN NULLIF(bp.zelle_cuenta, '') IS NOT NULL THEN 'zelle'
                 WHEN NULLIF(bp.tarjeta, '') IS NOT NULL THEN 'cuban_card' END
       FROM cerebro_beneficiario_parcial bp
      WHERE bp.conversation_id = v_op.conversation_id AND bp.actualizado > now() - interval '24 hours'));

  RETURN CASE
    WHEN v_riel IN ('zelle', 'clasica', 'tropical')
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'efectivo_usd'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_efectivo_usd'), '')::numeric, 29000)
    ELSE COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000)
  END;
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op  uuid;
  v_tot numeric;
  v_min numeric;
  v_obj numeric;
BEGIN
  SELECT o.id, o.quoted_source_amount INTO v_op, v_tot FROM remittance_operations o WHERE o.deal_id = p_deal;
  IF v_op IS NULL THEN RETURN NULL; END IF;
  v_min := cerebro_minimo_gyd(v_op);
  IF v_tot >= v_min AND NOT p_siempre THEN RETURN NULL; END IF;
  -- Another deal of this conversation is already waiting on its own objetivo: leave it alone.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio x
              WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL
                AND x.deal_id IS NOT NULL AND x.deal_id <> p_deal) THEN
    RETURN NULL;
  END IF;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido)
  VALUES (p_conv, greatest(v_min, v_tot), 'GYD', now(), p_deal, NULL, 'minimo del servicio (170)')
  ON CONFLICT (conversation_id) DO UPDATE SET
    monto      = greatest(CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.monto ELSE 0 END,
                          EXCLUDED.monto),
    moneda     = 'GYD',
    deal_id    = p_deal,
    pedido     = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.pedido ELSE EXCLUDED.pedido END,
    fijado_en  = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.fijado_en ELSE now() END,
    cerrado_en = NULL
  RETURNING monto INTO v_obj;
  RETURN v_obj;
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_cruzar_pendientes(p_deal uuid, p_excepto text DEFAULT NULL)
RETURNS TABLE(resultado text, trans_id text, n_refs integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_ok       CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  c_esperado CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_refs  text[];
  v_mont  numeric[];
  v_sim   record;
  v_real  record;
BEGIN
  -- One receipt per '---' block of the deal notes: its "DEPOSITO: <amount>" and "Ref: <digits>".
  SELECT array_agg(b.ref ORDER BY b.ord), array_agg(b.monto ORDER BY b.ord)
    INTO v_refs, v_mont
    FROM (SELECT x.ord,
                 (regexp_match(x.blk, 'Ref: ([0-9]{8,})'))[1] AS ref,
                 replace((regexp_match(x.blk, 'DEPOSITO: ([0-9][0-9,]*)'))[1], ',', '')::numeric AS monto
            FROM deals d,
                 LATERAL regexp_split_to_table(d.notes, E'\n---\n') WITH ORDINALITY AS x(blk, ord)
           WHERE d.id = p_deal) b
   WHERE b.ref IS NOT NULL AND b.monto IS NOT NULL
     AND b.ref IS DISTINCT FROM p_excepto
     AND EXISTS (SELECT 1 FROM depositos_mmg m
                  WHERE m.trans_id = b.ref AND m.consumido_en IS NULL AND m.anulado_en IS NULL);

  IF v_refs IS NULL THEN RETURN; END IF;

  SELECT * INTO v_sim FROM cerebro_cruzar_depositos(p_deal, v_refs, v_mont, c_ok, c_esperado, c_esperado, true);
  IF v_sim.resultado NOT IN ('verificado', 'verificado_incompleto') THEN
    RETURN QUERY SELECT v_sim.resultado, NULL::text, cardinality(v_refs); RETURN;
  END IF;
  SELECT * INTO v_real FROM cerebro_cruzar_depositos(p_deal, v_refs, v_mont, c_ok, c_esperado, c_esperado, false);
  RETURN QUERY SELECT v_real.resultado, v_real.trans_id, cardinality(v_refs);
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito(p_conv uuid, p_monto numeric, p_moneda text, p_stage uuid, p_nota text, p_comp_id text)
 RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
-- (114) The creado path's `ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL`
-- collides with this function's `deal_id` OUT parameter and raised
-- `column reference \"deal_id\" is ambiguous` on every new receipt (staging
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
  v_total   numeric;
  v_ventana integer := COALESCE(NULLIF(cerebro_config_get('completar_ventana_horas'), '')::int, 6);
  v_min_cup numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
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
  v_ref := NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '');

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

  -- (170) The open WAITING remesa this deposit completes. Read from the operation
  -- (114 stopped writing deals.stage_id, so the old stage filter never matched): a
  -- remesa of this chat still being verified or in incident, opened in the window,
  -- that is below its service minimum, still owes saldo, or this deposit alone is
  -- below the smallest minimum and so cannot be a remesa of its own. A remesa that is
  -- ready to transfer is never touched.
  IF NOT v_rev AND v_ex IS NULL THEN
    SELECT d.id INTO v_suma
      FROM remittance_operations o
      JOIN deals d ON d.id = o.deal_id
     WHERE o.conversation_id = p_conv
       AND d.status = 'open'
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND o.service_type = 'remesa'
       AND o.status IN ('deposit_verification', 'incident')
       AND o.created_at > now() - make_interval(hours => v_ventana)
       AND COALESCE(d.notes,'') LIKE '%DEPOSITO%'
       AND COALESCE(d.notes,'') NOT LIKE '%REFERENCIA IMPOSIBLE%'
       AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_envio(d.id) s), 0) > 0
            OR o.quoted_source_amount < cerebro_minimo_gyd(o.id)
            OR p_monto < v_min_cup)
     ORDER BY o.created_at DESC LIMIT 1;
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
    -- (170) Below the minimum of its service: wait for the rest.
    PERFORM cerebro_objetivo_minimo(p_conv, v_ex);
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  IF v_suma IS NOT NULL THEN
    SELECT o.quoted_source_amount + p_monto INTO v_total FROM remittance_operations o WHERE o.deal_id = v_suma;
    UPDATE deals
       SET value    = v_total,
           currency = p_moneda,
           notes    = COALESCE(notes,'') || E'\n---\n' || v_nota || chr(10)
                      || 'SUMADO AL MISMO ENVIO (170): completa la remesa abierta, total '
                      || rtrim(trim(to_char(v_total, 'FM999,999,999,990.99')), '.') || ' ' || p_moneda || '.',
           updated_at = now()
     WHERE id = v_suma
    RETURNING contact_id INTO v_contact;
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           quoted_source_amount = v_total,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.deal_id = v_suma;
    PERFORM cerebro_objetivo_atar(p_conv, v_suma);
    -- (170) The objetivo covers the whole remesa, so the cross waits until EVERY receipt
    -- of it is verified; then the earlier receipts that were never crossed are crossed
    -- now. This one is crossed by the Cerebro's own node right after this call.
    PERFORM cerebro_objetivo_minimo(p_conv, v_suma, true);
    PERFORM cerebro_cruzar_pendientes(v_suma, v_ref);
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

  -- (170) Below the minimum of its service: wait for the rest.
  IF NOT v_rev THEN PERFORM cerebro_objetivo_minimo(p_conv, v_id); END IF;

  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

-- (170) 168's late re-cross, generalised: any receipt of the operation whose MMG
-- email is now in the ledger, so a remesa paid in parts is re-crossed too.
CREATE OR REPLACE FUNCTION public.cerebro_recruzar_depositos_tardios()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op  record;
  v_res record;
  v_n   integer := 0;
BEGIN
  FOR v_op IN
    SELECT o.id, o.account_id, o.deal_id
      FROM remittance_operations o
      JOIN deals d ON d.id = o.deal_id
     WHERE o.status = 'deposit_verification'
       AND o.service_type = 'remesa'
       AND o.created_at > now() - interval '24 hours'
       AND o.updated_at < now() - interval '90 seconds'
       AND EXISTS (SELECT 1 FROM depositos_mmg m
                    WHERE m.consumido_en IS NULL AND m.anulado_en IS NULL
                      AND d.notes LIKE '%Ref: ' || m.trans_id || '%')
     FOR UPDATE OF o SKIP LOCKED
  LOOP
    SELECT * INTO v_res FROM cerebro_cruzar_pendientes(v_op.deal_id);
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
END $$;

REVOKE ALL ON FUNCTION public.cerebro_minimo_gyd(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_objetivo_minimo(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_cruzar_pendientes(uuid, text) FROM PUBLIC, anon, authenticated;
