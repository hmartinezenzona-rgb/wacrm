-- ROLLBACK of 213_visa_model.sql: restores the sixteen redefined functions exactly as before 213
-- (pg_get_functiondef md5 on staging, 2026-10-04: cerebro_registrar_deposito 9a74c0517af79a8152d25de55dd41644, cerebro_recruzar_depositos_tardios 25d0a246fd6ce10bb49c20197ff22a77, cerebro_riel_op 1333e4f34cc1313e90e01a4a016ad9cf, cerebro_minimo_gyd 7739f02da074f28217ab689c925aa202, cerebro_objetivo_minimo 2b65b250b59c88bb0c8bd4053fa3b3e4, cerebro_escribir_bloque_beneficiario fb184b7476457499c3f4498071911d71, cerebro_guardar_beneficiario_auto 1716c7f180aab58c2855ff109b139285, crm_beneficiarios_completos 3fedefe56611fb9953d90e67cabd2ddc, crm_operaciones_de_conversacion 2085e8a0374246be01e69f54e0656fa5, crm_cerrar_operacion_manual 24048751352a277453a13b715d149ad7, calculator_service_for_operation c6f6b8beae97623caf8d03d3c26730bd, calculator_resolve_operation_service e7d80344785326dffdadc8d5c944b96d, calculator_missing_rates 65a6ad589e9b55fcbe9d85a1519e3009, calculator_feed_operation d9f2f92cfa0d2f3318b938d3822d81c8, crm_resolve_pending_entry c85f1cd89ad7dde574b2d801898769f1, cerebro_avisar_envios_sin_beneficiario e23036390c2713e007064bf6a0adea11),
-- drops cerebro_visa_en_curso and crm_abrir_visa, restores the entries service CHECK without VISA and the audit action
-- CHECK without automation_visa_registered, and restores the cerebro_servicios 'visa' row. It refuses (and changes
-- nothing) when visa operations, VISA calculator lines or visa audit rows exist: they would violate the restored
-- CHECKs or lose their meaning; void or delete them first.
DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE service_type = 'visa') THEN
    RAISE EXCEPTION 'rollback 213 refused: visa operations exist';
  END IF;
  IF EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE service = 'VISA') THEN
    RAISE EXCEPTION 'rollback 213 refused: VISA calculator lines exist';
  END IF;
  IF EXISTS (SELECT 1 FROM remittance_admin_audit WHERE action = 'automation_visa_registered') THEN
    RAISE EXCEPTION 'rollback 213 refused: audit rows with the visa action exist';
  END IF;
END $guard$;

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
BEGIN
  v_rev := cerebro_es_revendedor(p_conv);
  -- (202) Decided up front (was computed after the movido search, inline): a recharge deposit can land on the recharge
  -- the customer's numbers already opened.
  v_recarga := NOT v_rev AND cerebro_recarga_en_curso(p_conv);
  -- (209) A combo deposit lands on the combo. When both apply the operation that is actually OPEN wins: the combo only
  -- when a combo operation is open and no recarga operation is; with both open, or only text, the recarga as before.
  v_combo := NOT v_rev AND cerebro_combo_en_curso(p_conv)
             AND (NOT v_recarga
                  OR (EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                                 AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled'))
                      AND NOT EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                                 AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled'))));
  IF v_combo THEN v_recarga := false; END IF;

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

  -- (160) movido branch: find the latest open remesa operation for this
  -- conversation that has no receipt yet, and is NOT (has vigente
  -- beneficiary AND positive saldo). The beneficiary+money conjunction
  -- is the exact structured equivalent of 156's `NOT (d.value > 0 AND
  -- COALESCE(d.notes,'') LIKE '%BENEFICIARIO%')`. An operation with a
  -- beneficiary but zero saldo is still the movido target.
  IF NOT v_rev THEN
    SELECT ro.id INTO v_ex
      FROM remittance_operations ro
     WHERE ro.conversation_id = p_conv
       AND ro.status NOT IN ('completed','cancelled')
       -- (202) or the recharge the customer's numbers opened
       -- (209) or the combo the customer is ordering
       AND (ro.service_type = 'remesa' OR (v_recarga AND ro.service_type = 'recarga')
            OR (v_combo AND ro.service_type = 'combo'))
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
         AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_operacion(ro.id) s), 0) > 0))
     ORDER BY ro.created_at DESC LIMIT 1;
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

  -- (160) Recarga 24 h window: now decided up front by cerebro_recarga_en_curso (202).

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
    PERFORM cerebro_objetivo_atar_op(p_conv, v_ex);
    -- (182 <- 170) Below the minimum of its service: wait for the rest.
    PERFORM cerebro_objetivo_minimo(p_conv, v_ex);
    -- (156) dual-write: insert parsed receipts for this operation.
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_ex
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    -- (202) a recharge takes any number typed since (no repeats)
    IF (SELECT service_type FROM remittance_operations WHERE id = v_ex) = 'recarga' THEN
      PERFORM crm_registrar_numeros_recarga(p_conv, cerebro_textos_cliente_recientes(p_conv));
    END IF;
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
    PERFORM cerebro_objetivo_atar_op(p_conv, v_suma);
    -- (182 <- 170) The objetivo covers the whole remesa.
    PERFORM cerebro_objetivo_minimo(p_conv, v_suma, true);
    -- (156) dual-write.
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_suma
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    -- (182 <- 170) The earlier receipts of the remesa that were never crossed are crossed now;
    -- this one is crossed by the Cerebro's own node right after this call.
    PERFORM cerebro_cruzar_pendientes(v_suma, v_ref);
    RETURN QUERY SELECT v_suma, 'sumado al envio abierto'::text, false, true; RETURN;
  END IF;

  -- (160) creado branch: INSERT remittance_operations directly, no deal.
  INSERT INTO remittance_operations (
    account_id, conversation_id, contact_id, deal_id, status,
    service_type, quoted_source_amount, source_currency, created_at,
    completed_at, cancelled_at, incident_reason
  )
  VALUES (
    (SELECT account_id FROM conversations WHERE id = p_conv),
    p_conv, v_contact, NULL,   -- deal_id = NULL (the whole point)
    cerebro_estado_desde_etapa(p_stage),
    CASE WHEN v_rev THEN 'remesa' WHEN v_combo THEN 'combo' WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
    p_monto, coalesce(p_moneda, 'GYD'), now(),
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'completed' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'cancelled' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident' THEN v_motivo ELSE NULL END
  )
  RETURNING id INTO v_id;

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
  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

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
       AND o.service_type IN ('remesa', 'combo')  -- (209) a combo is paid by MMG too
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

CREATE OR REPLACE FUNCTION public.cerebro_riel_op(p_op uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN o.service_type = 'recarga' THEN 'recarga'
              -- (209) a combo has its own rail (its recipients are 'combo' rows, but it can have none yet)
              WHEN o.service_type = 'combo' THEN 'combo' ELSE COALESCE(
    NULLIF(o.delivery_method, ''),
    (SELECT b.beneficiary_type FROM remittance_beneficiaries b
      WHERE b.operation_id = o.id AND b.status = 'vigente' ORDER BY b.position LIMIT 1),
    (SELECT p.tipo FROM cerebro_destino_pendiente p
      WHERE p.conversation_id = o.conversation_id AND p.actualizado > now() - interval '24 hours'),
    (SELECT CASE WHEN NULLIF(bp.zelle_cuenta, '') IS NOT NULL THEN 'zelle'
                 WHEN NULLIF(bp.tarjeta, '') IS NOT NULL THEN 'cuban_card' END
       FROM cerebro_beneficiario_parcial bp
      WHERE bp.conversation_id = o.conversation_id AND bp.actualizado > now() - interval '24 hours')) END
    FROM remittance_operations o
   WHERE o.id = p_op;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_minimo_gyd(p_op uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_riel text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = p_op) THEN RETURN NULL; END IF;
  v_riel := cerebro_riel_op(p_op);
  RETURN CASE
    WHEN v_riel = 'recarga'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200)
    -- (209) A combo: 25,000 GYD per recipient (at least one).
    WHEN v_riel = 'combo'
      THEN 25000 * greatest(1, (SELECT count(*) FROM remittance_beneficiaries b
                                 WHERE b.operation_id = p_op AND b.status = 'vigente'))
    WHEN v_riel IN ('zelle', 'clasica', 'tropical')
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'efectivo_usd'
      THEN cerebro_minimo_efectivo_gyd()  -- (188) 100 USD x the calculator cash rate
    ELSE COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000)
  END;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op     uuid := cerebro_resolve_op_id(p_deal);
  v_deal   uuid;
  v_tot    numeric;
  v_min    numeric;
  v_cot    numeric;
  v_prev   numeric;
  v_meta   numeric;
  v_pedido text;
  v_obj    numeric;
  v_hay    boolean;
BEGIN
  SELECT o.deal_id, o.quoted_source_amount INTO v_deal, v_tot FROM remittance_operations o WHERE o.id = v_op;
  IF v_op IS NULL OR NOT FOUND THEN RETURN NULL; END IF;
  v_min  := cerebro_minimo_gyd(v_op);
  v_cot  := cerebro_cotizacion_vigente(p_conv);
  v_prev := (SELECT x.monto FROM cerebro_objetivo_envio x WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL);
  v_meta := greatest(v_min, COALESCE(v_cot, v_prev, 0));
  v_pedido := CASE
    WHEN v_cot IS NOT NULL AND v_cot >= v_min THEN 'cotizacion'
    WHEN v_cot IS NULL AND v_prev IS NOT NULL AND v_prev > v_min THEN NULL
    ELSE 'minimo ' || CASE cerebro_riel_op(v_op)
                        WHEN 'zelle' THEN 'Zelle'
                        WHEN 'clasica' THEN 'Clásica'
                        WHEN 'tropical' THEN 'Tropical'
                        WHEN 'efectivo_usd' THEN 'efectivo en USD'
                        WHEN 'recarga' THEN 'recarga'
                        WHEN 'combo' THEN 'combo'  -- (209)
                        ELSE 'tarjeta CUP' END
  END;
  -- Another operation of this conversation is already waiting on its own objetivo: leave it alone.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio x
              WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL
                AND x.operation_id IS NOT NULL AND x.operation_id <> v_op) THEN
    RETURN NULL;
  END IF;
  v_hay := v_prev IS NOT NULL;
  IF v_tot >= v_meta AND NOT p_siempre AND NOT v_hay THEN RETURN NULL; END IF;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido, operation_id)
  VALUES (p_conv, greatest(v_meta, CASE WHEN p_siempre THEN v_tot ELSE 0 END), 'GYD', now(), v_deal, NULL,
          COALESCE(v_pedido, 'objetivo del envio'), v_op)
  ON CONFLICT (conversation_id) DO UPDATE SET
    monto        = EXCLUDED.monto,
    moneda       = 'GYD',
    deal_id      = v_deal,
    operation_id = v_op,
    pedido       = COALESCE(v_pedido, cerebro_objetivo_envio.pedido),
    fijado_en    = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.fijado_en ELSE now() END,
    cerrado_en   = NULL
  RETURNING monto INTO v_obj;
  RETURN v_obj;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_escribir_bloque_beneficiario(p_conv uuid, p_op uuid, p_bloque text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op      uuid := p_op;
  v_bi      integer;
  v_reparto boolean;
  v_zelle   integer;
  v_locked  boolean;
  v_account uuid;
BEGIN
  -- (210) A combo's recipients are written only by crm_registrar_destinatario_combo: this remesa writer (typed numbers,
  -- the remesa tools) neither writes on a combo nor opens a remesa next to an open combo. Owner test 2026-10-04: typed
  -- phones became 'cuban_card' generations on the combo and its recipients turned 'reemplazado'.
  IF v_op IS NULL THEN
    SELECT o.id INTO v_op FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at DESC LIMIT 1;
    IF v_op IS NOT NULL THEN RETURN v_op; END IF;
    v_op := cerebro_crear_operacion(p_conv);
  END IF;
  IF (SELECT o.service_type FROM remittance_operations o WHERE o.id = v_op) = 'combo' THEN
    RETURN v_op;
  END IF;

  SELECT admin_locked_fields ? 'beneficiaries', account_id INTO v_locked, v_account
    FROM remittance_operations WHERE id = v_op;
  IF v_locked THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason)
    VALUES (v_account, 'remittance_beneficiaries', v_op, 'beneficiaries', 'automation_write_suppressed',
            wacrm_current_actor(), 'beneficiaries locked by operator correction');
    RETURN v_op;
  END IF;

  SELECT coalesce(max(b.block_index), 0) + 1 INTO v_bi FROM remittance_beneficiaries b WHERE b.operation_id = v_op;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone,
                                        zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular, p.cuenta_zelle, p.monto, p.moneda, p.posicion, v_bi,
         'notes_parse', 'vigente'
    FROM cerebro_parsear_beneficiarios(p_bloque) p;

  -- (175) The newest generation is a reparto between cards: the latest Zelle stays vigente next to it.
  v_reparto := EXISTS (SELECT 1 FROM remittance_beneficiaries
                        WHERE operation_id = v_op AND block_index = v_bi
                          AND beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical'));
  IF v_reparto THEN
    SELECT max(block_index) INTO v_zelle FROM remittance_beneficiaries
     WHERE operation_id = v_op AND beneficiary_type = 'zelle' AND block_index < v_bi;
  END IF;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_bi AND status <> 'reemplazado'
     AND block_index IS DISTINCT FROM v_zelle;

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND block_index = v_zelle AND beneficiary_type = 'zelle' AND status <> 'vigente';

  RETURN v_op;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario_auto(p_conv uuid, p_tarjeta text, p_celular text, p_tarjeta_acum text, p_celular_acum text, p_exec text)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t text := cerebro_norm_tarjeta(p_tarjeta);
  v_c text := cerebro_norm_celular_cu(p_celular);
  v_ta text := cerebro_norm_tarjeta(p_tarjeta_acum);
  v_ca text := cerebro_norm_celular_cu(p_celular_acum);
  v_res record; v_out record;
  v_cash jsonb;
  v_falta text;
BEGIN
  -- (210) An open COMBO: typed numbers belong to its recipients, which the assistant saves with
  -- registrar_destinatario_combo (by combo number). Nothing is written here.
  IF EXISTS (SELECT 1 FROM remittance_operations o
              WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled')) THEN
    RETURN QUERY SELECT (SELECT o.id FROM remittance_operations o
                          WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled')
                          ORDER BY o.created_at DESC LIMIT 1),
      'combo en curso: los datos de los destinatarios los guarda el asistente con registrar_destinatario_combo'::text;
    RETURN;
  END IF;
  SELECT * INTO v_res FROM cerebro_resolver_operacion_beneficiario(p_conv,
           ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'],
           coalesce(NULLIF(v_t, '!'), NULLIF(v_ta, '!'), ''));
  -- (194) A CASH delivery has no card: a Cuban phone arriving alone is the cash recipient's phone. It used to be
  -- saved as a cuban_card beneficiary without card (a second vigente row: the remesa read incomplete) and the agent
  -- was told to ask for a card. A real card in the burst still goes the card way below.
  -- (201) A recharge has no card either: a Cuban number arriving alone is a recharge number.
  IF v_res.operation_id IS NOT NULL
     AND (SELECT o.service_type FROM remittance_operations o WHERE o.id = v_res.operation_id) = 'recarga'
     AND coalesce(NULLIF(v_t, '!'), '') = '' THEN
    RETURN QUERY SELECT v_res.operation_id,
      crm_registrar_numeros_recarga(p_conv, coalesce(cerebro_textos_cliente_recientes(p_conv), '') || ' ' || coalesce(p_celular, ''));
    RETURN;
  END IF;
  -- (202) No open operation but the customer asked for a recharge: the numbers open it (all typed since asking).
  IF v_res.operation_id IS NULL AND v_res.resultado = 'ninguna'
     AND coalesce(NULLIF(v_t, '!'), '') = '' AND cerebro_recarga_en_curso(p_conv) THEN
    RETURN QUERY SELECT (SELECT o.id FROM remittance_operations o WHERE FALSE),
      crm_registrar_numeros_recarga(p_conv, coalesce(cerebro_textos_cliente_recientes(p_conv), '') || ' ' || coalesce(p_celular, ''));
    RETURN;
  END IF;
  IF v_res.operation_id IS NOT NULL
     AND (SELECT o.delivery_method FROM remittance_operations o WHERE o.id = v_res.operation_id) = 'efectivo_usd'
     AND coalesce(NULLIF(v_t, '!'), '') = '' THEN
    IF v_c IS NULL OR v_c = '!' THEN
      RETURN QUERY SELECT v_res.operation_id, 'entrega en efectivo: no llego ningun celular valido de quien recibe'::text; RETURN;
    END IF;
    v_cash := crm_registrar_datos_entrega_efectivo(p_conv, v_c, NULL, NULL);
    v_falta := array_to_string(array_remove(ARRAY[
                 CASE WHEN v_cash ->> 'address' IS NULL THEN 'la direccion' END,
                 CASE WHEN v_cash ->> 'id_photo_wamid' IS NULL THEN 'la foto del carnet' END], NULL), ' y ');
    RETURN QUERY SELECT v_res.operation_id,
      ('guardado: celular ' || v_c || ' de quien recibe la entrega en efectivo.'
       || CASE WHEN v_falta = '' THEN ' Datos de la entrega completos.' ELSE ' FALTA: ' || v_falta || '. Pideselo al cliente.' END)::text;
    RETURN;
  END IF;
  IF v_res.operation_id IS NOT NULL THEN
    -- An open remesa: what arrived in this burst, partial, D1 (179).
    SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', coalesce(p_tarjeta, ''), coalesce(p_celular, ''), p_exec, v_res.operation_id, 'Registrar beneficiario auto');
  ELSIF v_res.resultado = 'ninguna' THEN
    -- No open remesa: only the complete pair opens one (as before).
    IF v_ta IS NOT NULL AND v_ta <> '!' AND v_ca IS NOT NULL AND v_ca <> '!' THEN
      SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', v_ta, v_ca, p_exec, NULL, 'Registrar beneficiario auto');
    ELSE
      RETURN QUERY SELECT NULL::uuid, 'sin envio abierto: se espera el dato que falta para abrirlo'::text; RETURN;
    END IF;
  ELSE
    -- Several open remesas the resolver cannot tell apart: the 179 path derives to a person.
    SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', coalesce(p_tarjeta, ''), coalesce(p_celular, ''), p_exec, NULL, 'Registrar beneficiario auto');
  END IF;
  IF v_out.accion LIKE '%Completo.%' THEN
    DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = p_conv;
  END IF;
  RETURN QUERY SELECT v_out.deal_id, v_out.accion;
END $function$;

CREATE OR REPLACE FUNCTION public.crm_beneficiarios_completos(p_operation_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (198) A recharge: every current row is a 'recarga' with a valid Cuban mobile, and there are as many as
  -- recharges (cerebro_recarga_unidades; with no matching price, at least one).
  SELECT coalesce((SELECT CASE WHEN o.service_type = 'recarga' THEN
           (SELECT count(*) > 0
                   AND bool_and(b.beneficiary_type = 'recarga'
                                AND coalesce(cerebro_norm_celular_cu(b.phone), '') ~ '^[0-9]{8}$')
                   AND count(*) >= coalesce(cerebro_recarga_unidades(o.quoted_source_amount), 0)
              FROM remittance_beneficiaries b
             WHERE b.operation_id = o.id AND b.status = 'vigente')
         -- (208) A combo: at least one current recipient, and every one has name, phone, address, reference and an
         -- amount of at least 25,000 GYD (the minimum per combo). The address names the province, and a second contact
         -- phone is optional (owner 2026-10-04).
         WHEN o.service_type = 'combo' THEN
           (SELECT count(*) > 0
                   AND bool_and(b.beneficiary_type = 'combo'
                                AND btrim(coalesce(b.name, '')) <> '' AND btrim(coalesce(b.phone, '')) <> ''
                                AND btrim(coalesce(b.address, '')) <> '' AND cerebro_combo_provincia(b.address) IS NOT NULL
                                AND btrim(coalesce(b.reference, '')) <> ''
                                AND coalesce(b.amount, 0) >= 25000)
              FROM remittance_beneficiaries b
             WHERE b.operation_id = o.id AND b.status = 'vigente')
         ELSE (
    SELECT
      count(*) > 0
      AND bool_and(
        CASE
          WHEN beneficiary_type = 'zelle' THEN
            btrim(coalesce(name, '')) <> '' AND btrim(coalesce(zelle_account, '')) <> ''
          -- (188) A cash recipient has no card: phone, address and ID-card photo (150).
          WHEN beneficiary_type = 'efectivo_usd' THEN
            btrim(coalesce(phone, '')) <> '' AND btrim(coalesce(address, '')) <> ''
            AND btrim(coalesce(id_photo_wamid, '')) <> ''
          ELSE
            btrim(coalesce(card_number, '')) <> '' AND btrim(coalesce(phone, '')) <> ''
        END
      )
    FROM remittance_beneficiaries
    WHERE operation_id = p_operation_id
      AND status = 'vigente'
         ) END
    FROM remittance_operations o
   WHERE o.id = p_operation_id), false);
$function$;

CREATE OR REPLACE FUNCTION public.crm_operaciones_de_conversacion(p_conversation_id uuid)
 RETURNS TABLE(resolver_resultado text, resolver_operation_id uuid, resolver_candidatas integer, operation_id uuid, operation_status text, operation_service_type text, operation_source_currency text, operation_destination_currency text, operation_delivery_method text, operation_deposit_method text, operation_quoted_source_amount numeric, operation_quoted_destination_amount numeric, operation_admin_locked_fields jsonb, operation_created_at timestamp with time zone, operation_completed_at timestamp with time zone, beneficiary_id uuid, beneficiary_type text, beneficiary_name text, beneficiary_card_number text, beneficiary_phone text, beneficiary_zelle_account text, beneficiary_delivery_method text, beneficiary_amount numeric, beneficiary_currency text, beneficiary_position integer, operation_quoted_destination_rate numeric, operation_quoted_destination_origin text, beneficiary_amount_origin text, operation_is_history boolean, operation_beneficiaries_complete boolean, operation_delivery_mode text, operation_delivered_at timestamp with time zone, beneficiary_address text, beneficiary_id_photo_wamid text, beneficiary_id_photo_url text, beneficiary_reference text, beneficiary_contact_phone text, operation_combo_costo_gyd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id            uuid;
  v_resolver_resultado    text;
  v_resolver_operation_id uuid;
  v_resolver_candidatas   integer;
BEGIN
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  SELECT c.account_id INTO v_account_id
    FROM conversations c
   WHERE c.id = p_conversation_id;

  -- Same 42501 whether the conversation doesn't exist or belongs to an
  -- account the caller isn't a member of — see 097's file header for why.
  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  -- Inlined, NOT called by name — see 097's file header's "WHY THE
  -- RESOLVER LOGIC IS INLINED" section. Unchanged by this migration: the
  -- resolver only ever looks at live (non-terminal) operations, regardless
  -- of the history rows the RETURN QUERY below now also surfaces.
  SELECT count(*) INTO v_resolver_candidatas
    FROM remittance_operations
   WHERE conversation_id = p_conversation_id
     AND status NOT IN ('completed', 'cancelled');

  IF v_resolver_candidatas = 0 THEN
    v_resolver_resultado := 'ninguna';
    v_resolver_operation_id := NULL;
  ELSIF v_resolver_candidatas = 1 THEN
    v_resolver_resultado := 'unica';
    SELECT o.id INTO v_resolver_operation_id
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled');
  ELSE
    v_resolver_resultado := 'ambigua';
    v_resolver_operation_id := NULL;
  END IF;

  RETURN QUERY
  WITH ops AS (
    -- Current open (non-terminal) remesa operations — same set the RPC
    -- has always returned.
    SELECT o.*, false AS is_history
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled')
       AND o.service_type IN ('remesa', 'recarga', 'combo')  -- (200) recharges too, (208) combos
    UNION ALL
    -- The 10 most recently completed remesa operations of the same
    -- conversation — read-only history. A completed operation can never
    -- also match the branch above (status is exclusive), so UNION ALL
    -- cannot duplicate a row.
    SELECT h.*, true AS is_history
      FROM (
        SELECT o2.*
          FROM remittance_operations o2
         WHERE o2.conversation_id = p_conversation_id
           AND o2.status = 'completed'
           AND o2.service_type IN ('remesa', 'recarga', 'combo')  -- (200), (208)
         ORDER BY o2.completed_at DESC
         LIMIT 10
      ) h
  )
  SELECT
    r.resultado,
    r.operation_id,
    r.candidatas,
    o.id,
    o.status,
    o.service_type,
    o.source_currency,
    o.destination_currency,
    o.delivery_method,
    o.deposit_method,
    o.quoted_source_amount,
    o.quoted_destination_amount,
    o.admin_locked_fields,
    o.created_at,
    o.completed_at,
    b.id,
    b.beneficiary_type,
    b.name,
    b.card_number,
    b.phone,
    b.zelle_account,
    b.delivery_method,
    b.amount,
    b.currency,
    b.position,
    o.quoted_destination_rate,
    o.quoted_destination_origin,
    b.amount_origin,
    o.is_history,
    CASE WHEN o.id IS NULL THEN NULL ELSE crm_beneficiarios_completos(o.id) END,
    o.delivery_mode,
    CASE WHEN o.is_history THEN o.completed_at ELSE NULL END,
    -- (189) a cash recipient (150): address and the ID-card photo, with the URL of the message it came in.
    b.address,
    b.id_photo_wamid,
    (SELECT m.media_url FROM messages m
      WHERE b.id_photo_wamid IS NOT NULL AND m.message_id = b.id_photo_wamid
        AND m.conversation_id = o.conversation_id
      ORDER BY m.created_at DESC LIMIT 1),
    -- (208) A combo recipient: how to get there and the second contact phone; the combo's cost (set by the admin).
    b.reference,
    b.contact_phone,
    o.combo_costo_gyd
  -- A single synthetic one-row source (no FROM) rather than a set-returning
  -- call, so the resolver values still surface even when zero operations
  -- match below (the 'ninguna' case) — LEFT JOIN against zero rows on the
  -- left would otherwise return zero rows overall, not one resolver-only row.
  FROM (SELECT v_resolver_resultado AS resultado, v_resolver_operation_id AS operation_id, v_resolver_candidatas AS candidatas) r
  LEFT JOIN ops o ON true
  LEFT JOIN remittance_beneficiaries b
         ON b.operation_id = o.id
        AND b.status = 'vigente'
  ORDER BY o.is_history ASC NULLS LAST, o.created_at DESC NULLS LAST, o.completed_at DESC NULLS LAST, b.position ASC NULLS LAST;
END $function$;

CREATE OR REPLACE FUNCTION public.crm_cerrar_operacion_manual(p_operation_id uuid, p_motivo text DEFAULT NULL::text, p_notify boolean DEFAULT false, p_delivery_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_status_before text;
  v_completed_at  timestamptz;
  v_motivo        text := coalesce(nullif(btrim(p_motivo), ''), 'Closed manually from the panel');
BEGIN
  SELECT account_id, status INTO v_account_id, v_status_before
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can close an operation manually' USING ERRCODE = '42501';
  END IF;
  -- (191) No typed reason any more: the fixed note above is audited unless one is given.
  IF length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'the reason must be at most 500 characters' USING ERRCODE = '22023';
  END IF;
  -- (196) The service chosen in the panel when the remesa has no beneficiary, so the calculator can price it.
  IF p_delivery_method IS NOT NULL THEN
    IF p_delivery_method NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo') THEN
      RAISE EXCEPTION 'unknown service: %', p_delivery_method USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente') THEN
      RAISE EXCEPTION 'this remesa already has a beneficiary: its service comes from it' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_status_before NOT IN ('ready_to_transfer', 'transferring') THEN
    RAISE EXCEPTION 'only a verified operation can be closed manually (status %)', v_status_before USING ERRCODE = '22023';
  END IF;

  -- One statement, like crm_entregar_operacion: completed_at (040) and the calculator feed read this row image.
  UPDATE remittance_operations
     SET status = 'completed', delivery_mode = 'closed_manually', delivered_by = auth.uid(),
         -- (196) In the same UPDATE, so the calculator feed (AFTER UPDATE OF status) sees the service.
         -- (200) 'recarga' is a kind of operation, not a delivery method: it sets service_type. (208) So is 'combo'.
         delivery_method = CASE WHEN p_delivery_method IN ('recarga', 'combo') THEN delivery_method ELSE coalesce(p_delivery_method, delivery_method) END,
         service_type = CASE WHEN p_delivery_method IN ('recarga', 'combo') THEN p_delivery_method ELSE service_type END,
         -- (191) Silent by default (p_notify false); the bell on the panel can turn the notice on.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'completed' END
   WHERE id = p_operation_id
  RETURNING completed_at INTO v_completed_at;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_manual_close', wacrm_current_actor(),
          v_motivo, jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', 'completed', 'delivery_mode', 'closed_manually', 'notify', p_notify)
            || CASE WHEN p_delivery_method IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('delivery_method', p_delivery_method) END);

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;

CREATE OR REPLACE FUNCTION public.calculator_service_for_operation(p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE lower(coalesce(p_delivery_method, ''))
           WHEN 'cuban_card'            THEN 'CUP'
           WHEN 'multiple_distribution' THEN 'CUP'
           WHEN 'zelle'                 THEN 'ZELLE'
           WHEN 'clasica'               THEN 'CLASICA'
           WHEN 'tropical'              THEN 'TROPICAL'
           -- (193) Cash dollars delivered in Cuba: their own service, priced at the cash sale rate.
           WHEN 'efectivo_usd'          THEN 'EFECTIVO'
           -- (199) A beneficiary row of a recharge (one Cuban number per recharge).
           WHEN 'recarga'               THEN 'RECARGA'
           -- (209) A combo (its beneficiary rows are typed 'combo' and so is its service_type).
           WHEN 'combo'                 THEN 'COMBO'
           ELSE NULL
         END;
$function$;

CREATE OR REPLACE FUNCTION public.calculator_resolve_operation_service(p_operation_id uuid, p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
           -- (199) A recharge is priced as RECARGA whatever its rows say (even with no number yet).
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'recarga' THEN 'RECARGA'
           -- (209) A combo is priced as COMBO whatever its rows say.
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'combo' THEN 'COMBO'
           WHEN NOT EXISTS (
             SELECT 1 FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) THEN calculator_service_for_operation(p_delivery_method)
           WHEN (
             SELECT count(DISTINCT b.beneficiary_type)
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) = 1 THEN calculator_service_for_operation((
             SELECT b.beneficiary_type
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
              LIMIT 1
           ))
           ELSE NULL
         END;
$function$;

CREATE OR REPLACE FUNCTION public.calculator_missing_rates(p_service text, p_rates calculator_rate_versions)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_service
    WHEN 'CUP' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.cup_global_rate IS NULL THEN 'cupGlobalRate' END,
        CASE WHEN p_rates.usdt_sell_cup   IS NULL THEN 'usdtSellCup'   END,
        CASE WHEN p_rates.usdt_buy_gyd    IS NULL THEN 'usdtBuyGyd'    END
      ], NULL)
    -- (199) A recharge: its USDT cost and the USDT buy rate (its price comes from the deposit, see the feed).
    WHEN 'RECARGA' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.recarga_costo_usdt IS NULL THEN 'recargaCostoUsdt' END,
        CASE WHEN p_rates.usdt_buy_gyd       IS NULL THEN 'usdtBuyGyd'       END
      ], NULL)
    -- (209) A combo depends on no rate: its cost is entered on the operation (the feed names comboCosto).
    WHEN 'COMBO' THEN ARRAY[]::text[]
    -- (193) Cash: the shared buy rate and the cash sale rate (efectivo_usd_gyd), not the Zelle sale rate.
    WHEN 'EFECTIVO' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.usdt_buy_gyd     IS NULL THEN 'usdtBuyGyd'     END,
        CASE WHEN p_rates.efectivo_usd_gyd IS NULL THEN 'efectivoUsdGyd' END
      ], NULL)
    ELSE
      array_remove(ARRAY[
        CASE WHEN p_rates.usdt_buy_gyd  IS NULL THEN 'usdtBuyGyd'  END,
        CASE WHEN p_rates.usdt_sell_gyd IS NULL THEN 'usdtSellGyd' END
      ], NULL)
  END;
$function$;

CREATE OR REPLACE FUNCTION public.calculator_feed_operation(p_operation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op        remittance_operations;
  v_rates     calculator_rate_versions;
  v_sell      numeric;
  v_part      record;
  v_missing   text[];
  v_basis     numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_currency  text;
  v_customer  text;
  v_entry_id  uuid;
  v_first_id  uuid;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.status <> 'completed' THEN
    RETURN NULL;
  END IF;

  IF v_op.quoted_source_amount IS NULL OR v_op.quoted_source_amount <= 0 THEN
    RETURN NULL;
  END IF;

  v_rates := calculator_rates_vigentes(v_op.account_id);

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  FOR v_part IN SELECT * FROM calculator_operation_parts(v_op, v_rates) LOOP
    v_basis     := v_part.basis;
    v_amount    := NULL;
    v_facturado := NULL;
    v_invertido := NULL;
    v_missing   := calculator_missing_rates(v_part.service, v_rates) || coalesce(v_part.missing, ARRAY[]::text[]);
    -- (199) a recharge whose deposit matches no recharge price cannot be priced
    IF v_part.service = 'RECARGA' AND cerebro_recarga_precio(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['recargaPrecioGyd'];
    END IF;
    -- (209) a combo whose cost the admin has not entered yet stays pending
    IF v_part.service = 'COMBO' AND v_op.combo_costo_gyd IS NULL THEN
      v_missing := v_missing || ARRAY['comboCosto'];
    END IF;
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' WHEN v_part.service = 'RECARGA' THEN 'REC'
                        WHEN v_part.service = 'COMBO' THEN 'GYD' ELSE 'USD' END;
    -- (193) The sale rate of the line: a cash dollar sells at efectivo_usd_gyd; every other USD service at
    -- usdt_sell_gyd. The cost (usdt_buy_gyd) is shared. Snapshotted in usdt_sell_gyd (= the sale rate used).
    v_sell      := CASE WHEN v_part.service = 'EFECTIVO' THEN v_rates.efectivo_usd_gyd
                        -- (199) a recharge sells at the price its deposit pays (198 cerebro_recarga_precio)
                        WHEN v_part.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis)
                        ELSE v_rates.usdt_sell_gyd END;

    IF v_part.service = 'COMBO' THEN
      -- (209) facturado = the verified deposit (GYD), invertido = the cost entered on the operation.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := v_op.combo_costo_gyd;
      END IF;
    ELSIF v_basis IS NOT NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := calculator_amount_from_basis(v_part.service, v_basis, v_rates.cup_global_rate, v_sell);
      v_facturado := calculator_facturado(v_part.service, v_amount, v_rates.cup_global_rate, v_sell);
      v_invertido := CASE WHEN v_part.service = 'RECARGA'
                          -- (199) units x USDT cost per recharge x USDT buy rate (the guide's "rec promo" line)
                          THEN v_amount * v_rates.recarga_costo_usdt * v_rates.usdt_buy_gyd
                          ELSE calculator_invertido(v_part.service, v_amount, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd) END;
    END IF;

    IF v_basis IS NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_missing := ARRAY['beneficiaryAmounts'];
    END IF;

    IF v_amount IS NULL OR v_amount <= 0 THEN
      v_amount := v_part.placeholder_amount;
      v_facturado := NULL;
      v_invertido := NULL;
      IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_missing := ARRAY['beneficiaryAmounts'];
      END IF;
    END IF;

    -- (209) The cost of a combo is entered by hand and can change. Completed lines are append-only (149), so a live COMBO
    -- line whose figures differ is VOIDED here (figures untouched) and the upsert below revives that row with the new
    -- ones, the way a reverted-then-completed operation is re-fed. Identical figures: nothing is touched (idempotent).
    IF v_part.service = 'COMBO' THEN
      UPDATE remittance_calculator_entries e
         SET status = 'void', voided_at = clock_timestamp(), void_reason = 'combo cost or deposit changed; re-fed'
       WHERE e.account_id = v_op.account_id AND e.operation_id = v_op.id AND e.source = 'completed_operation'
         AND e.service = 'COMBO' AND e.status <> 'void'
         AND (e.status IS DISTINCT FROM CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END
              OR e.amount IS DISTINCT FROM v_amount OR e.facturado_gyd IS DISTINCT FROM v_facturado
              OR e.invertido_gyd IS DISTINCT FROM v_invertido OR e.basis_gyd IS DISTINCT FROM v_basis);
    END IF;

    INSERT INTO remittance_calculator_entries (
      account_id, source, status, operation_id, entry_date, customer_name,
      service, amount, amount_currency, basis_gyd,
      cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id,
      facturado_gyd, invertido_gyd, retorno_gyd,
      missing_inputs, delivery_mode, actor_user_id, completed_at, cost_gyd, sale_gyd
    ) VALUES (
      v_op.account_id, 'completed_operation',
      CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END,
      v_op.id, coalesce(v_op.completed_at, clock_timestamp())::date, v_customer,
      v_part.service, v_amount, v_currency, v_basis,
      -- (199) A RECARGA line reads like a manual "rec promo" one: cup_rate = USDT rate, cost_gyd = USDT cost, sale_gyd = price.
      -- (209) A COMBO line snapshots no rate (it does not depend on them).
      CASE WHEN v_part.service = 'COMBO' THEN NULL ELSE v_rates.cup_global_rate END,
      CASE WHEN v_part.service = 'COMBO' THEN NULL
           WHEN v_part.service = 'RECARGA' THEN v_rates.usdt_buy_gyd ELSE v_rates.usdt_sell_cup END,
      CASE WHEN v_part.service = 'COMBO' THEN NULL ELSE v_rates.usdt_buy_gyd END,
      CASE WHEN v_part.service = 'COMBO' THEN NULL ELSE v_sell END, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp()),
      CASE WHEN v_part.service = 'RECARGA' THEN v_rates.recarga_costo_usdt
           WHEN v_part.service = 'COMBO' THEN v_op.combo_costo_gyd END,
      CASE WHEN v_part.service = 'RECARGA' THEN v_sell
           WHEN v_part.service = 'COMBO' THEN v_facturado END
    )
    ON CONFLICT (account_id, operation_id, service) WHERE source = 'completed_operation'
    DO UPDATE SET
      status          = EXCLUDED.status,
      entry_date      = EXCLUDED.entry_date,
      customer_name   = EXCLUDED.customer_name,
      amount          = EXCLUDED.amount,
      amount_currency = EXCLUDED.amount_currency,
      basis_gyd       = EXCLUDED.basis_gyd,
      cup_global_rate = EXCLUDED.cup_global_rate,
      cup_rate        = EXCLUDED.cup_rate,
      usdt_buy_gyd    = EXCLUDED.usdt_buy_gyd,
      usdt_sell_gyd   = EXCLUDED.usdt_sell_gyd,
      rate_version_id = EXCLUDED.rate_version_id,
      facturado_gyd   = EXCLUDED.facturado_gyd,
      invertido_gyd   = EXCLUDED.invertido_gyd,
      retorno_gyd     = EXCLUDED.retorno_gyd,
      missing_inputs  = EXCLUDED.missing_inputs,
      delivery_mode   = EXCLUDED.delivery_mode,
      actor_user_id   = EXCLUDED.actor_user_id,
      completed_at    = EXCLUDED.completed_at,
      cost_gyd        = EXCLUDED.cost_gyd,
      sale_gyd        = EXCLUDED.sale_gyd,
      voided_at       = NULL,
      void_reason     = NULL
    WHERE remittance_calculator_entries.status = 'void'
    RETURNING id INTO v_entry_id;

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_resolve_pending_entry(p_entry_id uuid, p_rates jsonb, p_reason text)
 RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry     remittance_calculator_entries;
  v_before    jsonb;
  v_basis     numeric;
  v_cup_glob  numeric;
  v_cup_rate  numeric;
  v_buy       numeric;
  v_sell      numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_missing   text[];
  v_key       text;
  v_value     numeric;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin') THEN
    RAISE EXCEPTION 'not authorized to resolve ledger entries' USING ERRCODE = '42501';
  END IF;

  IF v_entry.status <> 'verified_pending' THEN
    RAISE EXCEPTION 'only a pending entry can be resolved' USING ERRCODE = '22023';
  END IF;

  -- (209) A COMBO line is priced by the combo's cost (crm_set_combo_costo, panel), never by rates.
  IF v_entry.service = 'COMBO' THEN
    RAISE EXCEPTION 'a combo line is resolved by entering the combo cost in the panel, not with rates' USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'a reason of at least 5 characters is required' USING ERRCODE = '22023';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup', 'efectivo_usd_gyd') THEN
      RAISE EXCEPTION 'unknown rate: %', v_key USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_rates -> v_key) <> 'number' THEN
      RAISE EXCEPTION 'rate % must be a number', v_key USING ERRCODE = '22023';
    END IF;
    v_value := (p_rates ->> v_key)::numeric;
    IF v_value <= 0 OR v_value >= 1e9 THEN
      RAISE EXCEPTION 'rate % must be greater than 0 and less than 1e9', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_before := to_jsonb(v_entry);

  -- coalesce, not overwrite: what the entry already recorded wins.
  v_cup_glob := coalesce(v_entry.cup_global_rate, (p_rates ->> 'cup_global_rate')::numeric);
  v_cup_rate := coalesce(v_entry.cup_rate,        (p_rates ->> 'usdt_sell_cup')::numeric);
  v_buy      := coalesce(v_entry.usdt_buy_gyd,    (p_rates ->> 'usdt_buy_gyd')::numeric);
  -- (193) A cash line sells at the cash rate.
  v_sell     := coalesce(v_entry.usdt_sell_gyd,
                         CASE WHEN v_entry.service = 'EFECTIVO' THEN (p_rates ->> 'efectivo_usd_gyd')::numeric
                              ELSE (p_rates ->> 'usdt_sell_gyd')::numeric END);

  IF v_entry.service = 'CUP' THEN
    v_missing := array_remove(ARRAY[
      CASE WHEN v_cup_glob IS NULL THEN 'cupGlobalRate' END,
      CASE WHEN v_cup_rate IS NULL THEN 'usdtSellCup'   END,
      CASE WHEN v_buy      IS NULL THEN 'usdtBuyGyd'    END
    ], NULL);
  ELSE
    v_missing := array_remove(ARRAY[
      CASE WHEN v_buy  IS NULL THEN 'usdtBuyGyd'  END,
      CASE WHEN v_sell IS NULL THEN CASE WHEN v_entry.service = 'EFECTIVO' THEN 'efectivoUsdGyd' ELSE 'usdtSellGyd' END END
    ], NULL);
  END IF;

  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'still missing required rate(s): %', array_to_string(v_missing, ', ')
      USING ERRCODE = '22023';
  END IF;

  -- The deposit is re-read from the operation rather than trusted from the
  -- pending row, whose `amount` column held the deposit as a placeholder.
  -- (142) A line of a MIXED remesa is priced on its own share of the
  -- deposit (basis_gyd), never on the whole deposit.
  IF v_entry.basis_gyd IS NOT NULL THEN
    v_basis := v_entry.basis_gyd;
  ELSIF EXISTS (SELECT 1 FROM remittance_calculator_entries o
                 WHERE o.account_id = v_entry.account_id
                   AND o.operation_id = v_entry.operation_id
                   AND o.source = 'completed_operation'
                   AND o.service <> v_entry.service
                   AND o.status <> 'void') THEN
    RAISE EXCEPTION 'this line belongs to a mixed remesa whose share is unknown: fix the beneficiary amounts and re-feed the operation'
      USING ERRCODE = '22023';
  ELSE
    SELECT quoted_source_amount INTO v_basis
      FROM remittance_operations WHERE id = v_entry.operation_id;
  END IF;

  v_amount    := calculator_amount_from_basis(v_entry.service, v_basis, v_cup_glob, v_sell);
  v_facturado := calculator_facturado(v_entry.service, v_amount, v_cup_glob, v_sell);
  v_invertido := calculator_invertido(v_entry.service, v_amount, v_cup_rate, v_buy);

  IF v_amount IS NULL OR v_facturado IS NULL OR v_invertido IS NULL THEN
    RAISE EXCEPTION 'the operation has no usable deposit amount to price' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_calculator_entries
     SET status          = 'completed',
         amount          = v_amount,
         cup_global_rate = v_cup_glob,
         cup_rate        = v_cup_rate,
         usdt_buy_gyd    = v_buy,
         usdt_sell_gyd   = v_sell,
         facturado_gyd   = v_facturado,
         invertido_gyd   = v_invertido,
         retorno_gyd     = v_facturado - v_invertido,
         missing_inputs  = NULL
   WHERE id = p_entry_id
   RETURNING * INTO v_entry;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, action, actor, reason, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id,
          'calculator_pending_resolved', wacrm_current_actor(), btrim(p_reason),
          v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_avisar_envios_sin_beneficiario(p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(sin_destino integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_repetir int; v_silencio int;
  v_ahora_gy timestamp; v_desde time; v_hasta time;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; r record;
BEGIN
  v_min      := COALESCE(p_minutos,     NULLIF(cerebro_config_get('sin_beneficiario_min'), '')::int, 30);
  v_repetir  := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('sin_beneficiario_repetir_min'), '')::int, 120);
  v_silencio := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_silencio_humano_min'), '')::int, 20);
  v_desde    := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_desde'), '')::time, (SELECT abre FROM cerebro_horario()));
  v_hasta    := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_hasta'), '')::time, (SELECT cierra FROM cerebro_horario()));

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF EXTRACT(DOW FROM v_ahora_gy) = 0
     OR v_ahora_gy::time < v_desde OR v_ahora_gy::time >= v_hasta THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  FOR r IN
    SELECT op.id, op.deal_id, op.account_id, op.contact_id, op.conversation_id,
           op.quoted_source_amount AS value, op.source_currency AS currency,
           c.name, c.phone, dep.dinero_dentro
      FROM remittance_operations op
      JOIN conversations v ON v.id = op.conversation_id
      JOIN contacts      c ON c.id = v.contact_id
      CROSS JOIN LATERAL (
        SELECT max(m.consumido_en) AS dinero_dentro
          FROM depositos_mmg m
         WHERE m.operation_id = op.id
           AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) dep
     WHERE COALESCE(op.service_type, 'remesa') <> 'recarga'
       AND op.status IN ('deposit_verification', 'ready_to_transfer')
       AND dep.dinero_dentro IS NOT NULL
       AND dep.dinero_dentro < now() - make_interval(mins => v_min)
       AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b
                        WHERE b.operation_id = op.id AND b.status = 'vigente')
       AND NOT EXISTS (SELECT 1 FROM messages m
                        WHERE m.conversation_id = op.conversation_id
                          AND m.sender_type = 'agent'
                          AND NOT COALESCE(m.ai_generated, false)
                          AND m.created_at > now() - make_interval(mins => v_silencio))
       AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                        WHERE a.clave = 'sin_beneficiario:' || coalesce(op.deal_id, op.id)::text
                          AND a.ultimo > now() - make_interval(mins => v_repetir))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) >= 86400
        THEN round(EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) / 86400)::text || ' dias'
      ELSE round(EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) / 3600)::text || ' h' END;

    INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
    SELECT r.account_id, p.user_id, 'envio_sin_beneficiario', r.conversation_id, r.contact_id,
           COALESCE(NULLIF(r.name, ''), r.phone) || ': '
             || rtrim(trim(to_char(r.value, 'FM999,999,999,990.99')), '.') || ' ' || r.currency
             || ' dentro y SIN DESTINATARIO, lleva ' || v_espera,
           'El deposito esta verificado y consumido, pero el envio NO tiene a quien '
             || 'transferirle: ni tarjeta, ni celular, ni cuenta Zelle. El envio sigue '
             || 'abierto y ahi se queda. '
             || 'OJO: el bot puede haberle dicho al cliente que sus datos quedaban '
             || 'anotados sin que se anotara nada - abra el chat y compruebe lo que se '
             || 'le prometio antes de escribirle. Si el cliente ya dio los datos, el '
             || 'arreglo es registrar el beneficiario por la via estructurada: se '
             || 'escribe la fila de remittance_beneficiaries (las funciones de la '
             || 'migracion 162, las mismas que usa el bot y el panel), no el bloque '
             || 'BENEFICIARIO en las notas del deal.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('sin_beneficiario:' || coalesce(r.deal_id, r.id)::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END;
$function$;

DROP FUNCTION IF EXISTS public.crm_abrir_visa(uuid, integer);
DROP FUNCTION IF EXISTS public.cerebro_visa_en_curso(uuid);

ALTER TABLE remittance_calculator_entries DROP CONSTRAINT remittance_calculator_entries_service_chk;
ALTER TABLE remittance_calculator_entries ADD CONSTRAINT remittance_calculator_entries_service_chk
  CHECK (service = ANY (ARRAY['CUP', 'ZELLE', 'MLC', 'CLASICA', 'TROPICAL', 'USDT', 'RECARGA', 'SALDO_MOVIL', 'DIRECTO', 'EFECTIVO', 'COMBO']));

ALTER TABLE remittance_admin_audit DROP CONSTRAINT remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action = ANY (ARRAY['automation_write_suppressed', 'automation_completion_suppressed', 'automation_revert_suppressed', 'human_correction', 'human_reassignment', 'human_deposit_verification', 'human_forced_verification', 'human_delivery', 'calculator_feed_failed', 'calculator_pending_resolved', 'human_beneficiary_added', 'automation_reparto_registered', 'human_calculator_correction', 'automation_cash_delivery_data_registered', 'automation_late_deposit_verification', 'human_manual_close', 'human_operation_deleted', 'automation_recharge_numbers_registered', 'automation_combo_recipient_registered', 'human_combo_cost_set']));

-- The cerebro_servicios 'visa' row as it was before 213 (staging, last updated 2026-08-19T14:00:18.201809+00:00).
UPDATE cerebro_servicios SET
  hechos = $v$Extension de visa en Guyana. El negocio NO hace el tramite: sube la aplicacion en linea en el sitio de inmigracion. Cuesta 5,000 GYD y se paga ANTES: el ultimo campo del formulario es la foto del recibo de pago. Condiciones: el pasaporte no puede estar vencido. Si han pasado 11 meses o mas sin hacer una extension, inmigracion cobra ademas una multa de 20,000 GYD. Despues de subir la aplicacion, inmigracion manda un PDF por correo y el negocio se lo reenvia con los pasos siguientes: (1) ir a inmigracion con el PDF impreso y pagar alli 5,125 GYD o lo que corresponda segun su tramite. Inmigracion queda aqui: https://g.co/kgs/5cm8mdK ; (2) a las dos semanas escribir para revisar si fue aprobada; (3) al aprobarse se entrega la carta de aprobacion para imprimir; (4) con esa carta, el pasaporte y una copia de la primera pagina, ir a la oficina de pasaporte antes de las 9am y recoger antes de las 4pm; ese paso no cuesta nada. La oficina de pasaporte queda aqui: https://g.co/kgs/D1psrd1 Inmigracion tarda de 1 a 3 semanas. PROHIBIDO ofrecer rebajas, descuentos o precios especiales. Si el cliente pide rebaja, di la tarifa fija y que cualquier rebaja la trata una persona del equipo.$v$,
  resumen = $v$Extension de visa en Guyana: sube la aplicacion online, 4,000 GYD, pasaporte vigente.$v$,
  notas_internas = $v$Osmany 8-ago: dijo que subiria a 5,000 GYD "pronto", sin fecha. || 19-AGO-2026: APLICADA LA SUBIDA A 5,000 GYD por decision de Humberto; el precio ya cambio en el negocio. La extension de visa cuesta 5,000 GYD. Revertir con backups/2026-08-19-visa-antes-de-5000.sql. OJO: los 5,125 GYD que se pagan EN inmigracion y la multa de 20,000 GYD son otra cosa, no se tocan.$v$
 WHERE clave = 'visa';

