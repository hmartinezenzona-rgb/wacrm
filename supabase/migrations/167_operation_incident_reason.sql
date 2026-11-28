-- =====================================================================
-- 167 — an operation carries its own incident reason
--
-- PROBLEM
--   notify_operation_incidencia (114) builds the MOTIVO line of the
--   incident notification out of the LAST LINE of the linked deal's
--   deals.notes (114:298-302). After 160 nothing writes an incident
--   motive into deals.notes any more (160's header says so; v_nota is
--   consumed only by cerebro_parsear_comprobantes), so that last line is
--   whatever unrelated text was written last — measured on staging, a
--   deal-linked operation driven to incident showed
--   "VERIFICADO EN PANEL por un operador del CRM" as its MOTIVO, a stale
--   wrong motive with the same confident formatting as a right one.
--
-- FIX
--   1. Add remittance_operations.incident_reason (text, nullable, no
--      default). Additive: no positional INSERT into this table exists in
--      the catalog (all four INSERTs carry a column list), no
--      SELECT * FROM remittance_operations, and no function RETURNS
--      remittance_operations / SETOF. The only composite consumer,
--      calculator_operation_parts(p_op remittance_operations, ...), reads
--      fields by name (p_op.id, p_op.quoted_source_amount,
--      p_op.delivery_method). All four claims verified against the live
--      catalog before this column was added.
--   2. notify_operation_incidencia reads NEW.incident_reason. The whole
--      IF NEW.deal_id IS NOT NULL ... SELECT d.notes block and the
--      v_deal_notes declaration go; the fallback string and every other
--      line of the message stay byte-identical. The function no longer
--      names deals at all.
--   3. Every writer that moves an operation to 'incident' and already
--      knows a reason persists it in the SAME statement that sets status
--      (the AFTER trigger fires on UPDATE OF status, i.e. when the SET
--      list names status, so a later write would be too late):
--        - cerebro_registrar_deposito  -> the REFERENCIA IMPOSIBLE text
--        - cerebro_cruzar_deposito     -> the SIN VERIFICAR / ALERTA CASE
--        - cerebro_cruzar_depositos    -> v_fallo
--      Sites that reach incident without a reason text leave the column
--      NULL and the trigger's honest fallback renders:
--      remittance_operations_completion_guard (coerced completed ->
--      incident) and crm_verificar_deposito (verificado_de_mas). See the
--      unit report for the full inventory.
--
-- INVARIANT: incident_reason is meaningful only while status = 'incident'.
--   Every write of the column in this migration sits in the same SET as
--   status and writes NULL whenever the new status is not 'incident', so
--   these paths can never leave a stale reason behind. Writers that could
--   still move a row OUT of incident without clearing it are out of scope
--   here and are reported, not silently "fixed".
--
-- ROLLBACK: ROLLBACK-167-operation-incident-reason.sql
-- Guarded by supabase/staging/assertions/operation-incident-reason.sql
-- =====================================================================

ALTER TABLE remittance_operations ADD COLUMN incident_reason text;

COMMENT ON COLUMN remittance_operations.incident_reason IS
  '167. Free-text motive for status=''incident'', persisted by the '
  'incident writer in the same statement that sets status. NULL when the '
  'writer knows no reason; notify_operation_incidencia then renders the '
  'generic fallback. Meaningful only while status = ''incident''.';


-- ---------------------------------------------------------------------
-- 1. notify_operation_incidencia reads the operation column, not the deal
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION notify_operation_incidencia()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_motivo   text;
  v_nombre   text;
  v_telefono text;
  v_cliente  text;
BEGIN
  IF NEW.status IS DISTINCT FROM 'incident' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'incident' THEN
    RETURN NEW;
  END IF;

  SELECT NULLIF(btrim(c.name), ''), NULLIF(btrim(c.phone), '')
    INTO v_nombre, v_telefono
    FROM contacts c
   WHERE c.id = coalesce(NEW.contact_id,
                          (SELECT cv.contact_id FROM conversations cv WHERE cv.id = NEW.conversation_id));

  v_cliente := coalesce(v_nombre, 'Cliente sin nombre');

  -- 167: the motive is the operation's own incident_reason, written by the
  -- same statement that moved the row to incident. No deals read remains.
  v_motivo := NULLIF(btrim(NEW.incident_reason), '');

  INSERT INTO notifications (
    account_id, user_id, type, conversation_id, contact_id,
    actor_user_id, title, body
  )
  SELECT NEW.account_id,
         p.user_id,
         'deal_incidencia',
         NEW.conversation_id,
         NEW.contact_id,
         NULL,
         'INCIDENCIA | ' || v_cliente || ' | WhatsApp ' || coalesce(v_telefono, 'sin número'),
         'CLIENTE: ' || v_cliente || chr(10)
         || 'WHATSAPP: ' || coalesce(v_telefono, 'sin número') || chr(10)
         || 'ENVÍO: ' || coalesce(NEW.service_type, 'remesa') || chr(10)
         || 'MONTO: ' || to_char(coalesce(NEW.quoted_source_amount, 0), 'FM999,999,999') || ' '
                       || coalesce(NEW.source_currency, 'GYD') || chr(10)
         || 'MOTIVO:' || chr(10)
         || coalesce(v_motivo, 'Un envío necesita revisión manual.')
    FROM profiles p
   WHERE p.account_id = NEW.account_id
     AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.user_id);

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[wacrm] notify_operation_incidencia failed for operation %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION notify_operation_incidencia() IS
  '114, reworked by 167. Ports notify_deal_incidencia (090) onto '
  'remittance_operations. The MOTIVO line comes from '
  'remittance_operations.incident_reason, persisted by the incident '
  'writer; falls back to a generic reason when the column is NULL. No '
  'longer reads deals.';

DROP TRIGGER IF EXISTS trg_notify_operation_incidencia ON remittance_operations;
CREATE TRIGGER trg_notify_operation_incidencia
  AFTER INSERT OR UPDATE OF status ON remittance_operations
  FOR EACH ROW
  EXECUTE FUNCTION notify_operation_incidencia();


-- ---------------------------------------------------------------------
-- 2. cerebro_registrar_deposito — REFERENCIA IMPOSIBLE persists its reason
--    (signature, OUT columns, ACL unchanged)
-- ---------------------------------------------------------------------

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
  v_ya      uuid;
  v_ex      uuid;
  v_suma    uuid;
  v_id      uuid;
  v_phone   text;
  v_ref     text;
  v_nota    text;
  v_motivo  text;
  v_contact uuid;
BEGIN
  v_rev := cerebro_es_revendedor(p_conv);

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
       AND ro.service_type = 'remesa'
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

  -- (160) sumado branch: op at deposit_verification with positive saldo.
  -- 156's v_suma had NO receipt guard and NO beneficiary guard — a
  -- second partial deposit on an already-beneficiary-assigned shipment
  -- still summed. Only saldo>0 is the discriminator.
  IF NOT v_rev AND v_ex IS NULL THEN
    SELECT ro.id INTO v_suma
      FROM remittance_operations ro
     WHERE ro.conversation_id = p_conv
       AND ro.status = 'deposit_verification'
       AND ro.service_type = 'remesa'
       AND (SELECT s.saldo FROM cerebro_saldo_operacion(ro.id) s) > 0
     ORDER BY ro.created_at DESC LIMIT 1;
  END IF;

  -- (160) Recarga 24 h window: use the latest CLOSED operation for this
  -- conversation instead of the max(deals.updated_at) with status <>
  -- 'open' OR stage = '1b36b34c'.
  IF NOT v_rev THEN
    SELECT EXISTS (
             SELECT 1 FROM messages m
              WHERE m.conversation_id = p_conv
                AND m.sender_type = 'customer'
                AND m.created_at > GREATEST(
                      now() - interval '24 hours',
                      COALESCE((SELECT max(op.updated_at) FROM remittance_operations op
                                 WHERE op.conversation_id = p_conv
                                   AND op.status IN ('completed','cancelled')),
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
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  -- (160) sumado branch: update the found op directly.
  IF v_suma IS NOT NULL THEN
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident'
                                  THEN v_motivo ELSE NULL END,
           quoted_source_amount = p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.id = v_suma;
    PERFORM cerebro_objetivo_atar_op(p_conv, v_suma);
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
    CASE WHEN v_rev THEN 'remesa' WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
    p_monto, coalesce(p_moneda, 'GYD'), now(),
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'completed' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'cancelled' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident' THEN v_motivo ELSE NULL END
  )
  RETURNING id INTO v_id;

  IF NOT v_rev THEN PERFORM cerebro_objetivo_atar_op(p_conv, v_id); END IF;

  -- (156) dual-write: parse and insert receipts linked to this new op.
  INSERT INTO public.remittance_operation_receipts (
    operation_id, conversation_id, comp_id, amount, currency, receipt_status,
    recipient, via, reference, receipt_date, correct_destination, source)
  SELECT v_id, p_conv, p.comp_id, p.amount, p.currency, p.receipt_status,
         p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
    FROM cerebro_parsear_comprobantes(v_nota) p
  ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;

  -- (160) OUT column keeps its name 'deal_id' but now carries the
  -- operation id. Callers (n8n node) pass it back to
  -- cerebro_cruzar_deposito which now calls cerebro_resolve_op_id.
  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

REVOKE EXECUTE ON FUNCTION cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text)
  TO service_role;


-- ---------------------------------------------------------------------
-- 3. cerebro_cruzar_deposito — the SIN VERIFICAR / ALERTA CASE persists
--    its reason (signature, OUT columns, ACL unchanged)
-- ---------------------------------------------------------------------

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
           SET consumido_en = now(), operation_id = v_op_id,
               deal_id = COALESCE(deal_id, (SELECT deal_id FROM remittance_operations WHERE id = v_op_id))
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
        'VERIFICADO: casa con el correo de MMG (TransID ' || v_trans || ') '
        || '- COINCIDENCIA APROXIMADA: el comprobante decia ' || v_ref
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

REVOKE EXECUTE ON FUNCTION cerebro_cruzar_deposito(uuid,text,numeric,uuid,uuid,uuid,bool)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_cruzar_deposito(uuid,text,numeric,uuid,uuid,uuid,bool)
  TO service_role;


-- ---------------------------------------------------------------------
-- 4. cerebro_cruzar_depositos — v_fallo persists the reason when the
--    burst fails; the over-deposit (saldo < 0) branch has no reason text
--    and stays NULL. (signature, OUT columns, ACL unchanged)
-- ---------------------------------------------------------------------

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
  v_op_id uuid;
BEGIN
  -- (160) Resolve either flavour.
  v_op_id := cerebro_resolve_op_id(p_deal);

  v_n := COALESCE(array_length(p_refs, 1), 0);

  SELECT s.objetivo, s.moneda INTO v_obj, v_mon FROM cerebro_saldo_operacion(v_op_id) s;

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
        FROM cerebro_cruzar_deposito(v_op_id, p_refs[1], p_montos[1],
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
        FROM cerebro_cruzar_deposito(v_op_id, p_refs[v_i], p_montos[v_i],
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
          FROM cerebro_cruzar_deposito(v_op_id, p_refs[v_i], p_montos[v_i],
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
    FROM cerebro_saldo_operacion(v_op_id) s;
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

  IF NOT p_simular THEN
    -- (160) Write status directly on the operation; no deals touch.
    UPDATE remittance_operations
       SET status = cerebro_estado_desde_etapa(v_stage_final),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(v_stage_final) = 'incident'
                                  THEN v_fallo ELSE NULL END,
           updated_at = now()
     WHERE id = v_op_id;
    GET DIAGNOSTICS v_tocados = ROW_COUNT;
    IF v_todos AND v_saldo IS NOT NULL AND v_saldo = 0 THEN
      PERFORM cerebro_objetivo_cerrar_op(v_op_id);
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

REVOKE EXECUTE ON FUNCTION cerebro_cruzar_depositos(uuid,text[],numeric[],uuid,uuid,uuid,bool)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_cruzar_depositos(uuid,text[],numeric[],uuid,uuid,uuid,bool)
  TO service_role;

NOTIFY pgrst, 'reload schema';

