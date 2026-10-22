-- =====================================================================
-- 267 -- cerebro_registrar_deposito decides the service with the resolver (staging first)
--
-- odd/tasks/service-resolution.md (S3 part 2). The deposit used to read its own flags (cerebro_recarga_en_curso /
-- cerebro_combo_en_curso / cerebro_visa_en_curso) to choose the service of the operation it creates or joins. Those words
-- are now read once, by cerebro_resolver_servicio (265), so a deposit, the panel and the agent agree on one answer.
--
-- Changes against the live body (migration 232), nothing else:
--   - the transaction takes pg_advisory_xact_lock('cerebro_servicio:' || conversation), the lock 266 uses (re-entrant);
--   - the flags come from v_res = cerebro_resolver_servicio(conversation, NULL, NULL, this deposit): servicio 'recarga'
--     sets v_recarga, 'combo' sets v_combo, 'visa' sets v_visa. A resolver error (motivo 'error') keeps the remesa
--     fallback: all three flags false. When the resolver decides no service (servicio NULL: several open operations
--     with no deposit, ambiguous words) the live precedence (open operation, recarga > combo > visa) still applies, so
--     visa-model 5e holds. A reseller's deposit skips the resolver, as before;
--   - the holder lookup prefers the operation the resolver names (destino_operacion) when it is still open and eligible;
--   - when the resolver said accion 'convertir', the operation the deposit was attached to is converted right after the
--     attach by cerebro_aplicar_servicio(conversation, NULL, NULL, 'automation:registrar_deposito', NULL), which resolves
--     again under the same lock. Each branch (movido, sumado, creado) does it before its minimum / crossing calls.
--
-- Guarded by supabase/staging/assertions/deposito-resolver.sql. ROLLBACK: ROLLBACK-267-deposit-on-resolver.sql
-- =====================================================================

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
  -- 267: the service is decided by cerebro_resolver_servicio (265), from the customer's words, the open operations and
  -- this deposit amount. A reseller's deposit is always a remesa. A resolver error keeps the remesa fallback.
  IF NOT v_rev THEN
    v_res := cerebro_resolver_servicio(p_conv, NULL::text, NULL::text, p_monto);
    v_dest   := nullif(v_res ->> 'destino_operacion', '')::uuid;
    v_accion := v_res ->> 'accion';
    IF COALESCE(v_res ->> 'motivo', '') = 'error' THEN
      NULL;  -- fail open: remesa, all three flags stay false
    ELSIF v_res ->> 'servicio' IS NOT NULL THEN
      v_recarga := COALESCE((v_res ->> 'servicio') = 'recarga', false);
      v_combo   := COALESCE((v_res ->> 'servicio') = 'combo', false);
      v_visa    := COALESCE((v_res ->> 'servicio') = 'visa', false);
    ELSE
      -- No service decided (several open operations with no deposit, ambiguous words): the precedence of the live body
      -- (202, 209, 213) stays. The open operation wins; among several open ones recarga > combo > visa; with nothing open,
      -- the same order applies to the words.
      v_open_r := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_c := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_v := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'visa' AND o.status NOT IN ('completed', 'cancelled'));
      IF v_open_r OR v_open_c OR v_open_v THEN
        v_recarga := v_open_r;
        v_combo   := v_open_c AND NOT v_open_r;
        v_visa    := v_open_v AND NOT v_open_r AND NOT v_open_c;
      ELSE
        v_recarga := cerebro_recarga_en_curso(p_conv);
        v_combo   := NOT v_recarga AND cerebro_combo_en_curso(p_conv);
        v_visa    := NOT v_recarga AND NOT v_combo AND cerebro_visa_en_curso(p_conv);
      END IF;
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
            OR (v_visa AND ro.service_type = 'visa'))
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
    -- (267) the resolver said convert: the deposit is attached, so the service is decided again and converted here
    IF v_accion = 'convertir' THEN
      PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
    END IF;
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
    -- (267) the resolver said convert: the deposit is attached, so the service is decided again and converted here
    IF v_accion = 'convertir' THEN
      PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
    END IF;
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
    CASE WHEN v_rev THEN 'remesa' WHEN v_combo THEN 'combo' WHEN v_visa THEN 'visa' WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
    p_monto, coalesce(p_moneda, 'GYD'), now(),
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
  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_registrar_deposito(uuid, numeric, text, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_deposito(uuid, numeric, text, uuid, text, text) TO service_role;
