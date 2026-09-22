-- =====================================================================
-- 114 — Cutover: retire the deals->remittance_operations sync bridge,
--        drop the deal-stage delivery gate, move customer/admin
--        notifications onto remittance_operations, repoint the
--        panel-facing history/reconciliation views
--
-- SCOPE (SDD change port-chat-operations-calculator, Slice 11, task 11.1).
-- This is the ONE shared migration slice 11 exists for. It does NOT touch
-- production, does NOT re-register migration numbering against the
-- separate "cerebro" series (see the KNOWN OPEN RISK note at the very
-- end of this header — that is task 11.5/1.1b, human-only), and does NOT
-- import or modify any n8n workflow (also 11.5, human-only). It only
-- changes what THIS repository's schema/functions do.
--
-- ---------------------------------------------------------------------
-- WHAT "DUAL-WRITE" MEANT GOING INTO THIS MIGRATION (recap of 110)
-- ---------------------------------------------------------------------
--
-- Two independent mechanisms have been keeping `remittance_operations`
-- in sync with `deals` since 041/060 and 110:
--
--   (A) `trg_sync_operacion_desde_deal` (041/043/060) — an AFTER INSERT
--       OR UPDATE OF stage_id, value, contact_id, currency OR DELETE
--       trigger on `deals`. It derives `remittance_operations.status`
--       from `deals.stage_id` via `cerebro_estado_desde_etapa()`, mirrors
--       `quoted_source_amount`/`contact_id`, creates the operation row on
--       a deal INSERT it has never seen before, and cancels a live
--       operation when its deal is deleted. THIS is "the legacy sync
--       trigger" this task retires.
--
--   (B) Direct writes 110 added inside `cerebro_registrar_deposito`,
--       `cerebro_cruzar_deposito` and `cerebro_cruzar_depositos` — the
--       three n8n-facing functions — so `remittance_operations.status`
--       is set by the SAME function call, from the SAME stage value, as
--       `deals.stage_id`, instead of arriving as a side effect of (A).
--
-- Because (B) already writes `remittance_operations.status` directly at
-- every site that matters, (A) has been REDUNDANT for every stage/status
-- transition since 110 shipped — except for two things (A) is still the
-- ONLY mechanism for: creating the operation row on a brand-new deal
-- INSERT, and cancelling an operation when its deal is deleted. Both are
-- replaced below (sections 2 and 6) before (A) is dropped, so nothing
-- that worked through (A) stops working.
--
-- ---------------------------------------------------------------------
-- WHAT THIS MIGRATION ACTUALLY DOES, IN ORDER
-- ---------------------------------------------------------------------
--
--   1. Captures the live, unversioned `deals_stage_notify` trigger and
--      its function `notify_deal_stage_change()` verbatim (same pattern
--      as 109/112 — first time this drifted object is versioned), THEN
--      retires it, replacing it with an equivalent generic relay trigger
--      on `remittance_operations` (ANY status change, matching the
--      original's ANY stage_id change — the actual customer-facing
--      decision logic lives entirely in the receiving n8n workflow,
--      which reads `record.status`/`record.table` from the webhook
--      payload; repointing THAT workflow to the new payload shape is
--      task 11.5, human-only, "import n8n workflow").
--   2. Retires `trg_notify_deal_incidencia` (090) and replaces it with an
--      equivalent trigger on `remittance_operations` for
--      `status = 'incident'`, reusing the SAME admin in-app notification
--      shape (the `notifications` table), reading the incident reason
--      from the linked deal's notes when one exists (deal linkage and
--      `deals.notes` are NOT removed by this migration — see section 4).
--   3. Replaces `trg_sync_operacion_desde_deal` with a DELETE-only
--      cancellation trigger, preserving 060's "deleting a deal cancels
--      its live operation" safety net without the INSERT/UPDATE mirror
--      direction this task retires.
--   4. Updates `cerebro_registrar_deposito`, `cerebro_cruzar_deposito`
--      and `cerebro_cruzar_depositos` (the three n8n functions) so they
--      STOP writing `deals.stage_id` (the only column these three no
--      longer need to touch, now that neither the panel's delivery gate
--      nor any notification reads it — see decisions 1/2/3 below) while
--      leaving `deals.value`, `deals.currency`, `deals.notes` and the
--      brand-new-deal INSERT completely untouched — idempotency
--      (comp_id-in-notes), beneficiary parsing (`trg_sync_z_benef_desde_deal`,
--      unaffected, still fires off `deals.notes`) and revendedor/recarga
--      detection all still depend on `deals.notes`/`deals`-row existence
--      and are OUT OF SCOPE for this task. The brand-new-deal branch of
--      `cerebro_registrar_deposito` gains an explicit
--      `INSERT INTO remittance_operations` (replacing the row-creation
--      half of the trigger this migration drops), and the existing/open
--      deal branches' `remittance_operations` UPDATEs are extended to
--      also mirror `quoted_source_amount`/`contact_id` (replacing that
--      half of the same trigger).
--   5. Rewrites `crm_entregar_operacion` (task 11.1 item 2): removes the
--      requirement that the linked deal be in "Lista para transferir"
--      (`v_stage IS DISTINCT FROM v_lista`), gating solely on
--      `remittance_operations.status = 'ready_to_transfer'`; stops
--      writing `deals.stage_id`; writes status/evidence in ONE UPDATE on
--      `remittance_operations` (this also makes 108's careful two-
--      statement reordering fix unnecessary going forward — a single
--      UPDATE cannot present the calculator feed trigger with stale
--      evidence columns, because there is no second statement for it to
--      race against).
--   6. Rewrites `crm_verificar_deposito` and `crm_forzar_verificacion`
--      (099) the same way: their own deal-stage gate is removed (it was
--      already redundant with their primary
--      `remittance_operations.status` gate, and would otherwise become
--      systematically WRONG the moment `deals.stage_id` stops updating —
--      see item 4), `deals.stage_id` is no longer written (their
--      `deals.notes` rewrite is unchanged), and an explicit
--      `remittance_operations.status` UPDATE replaces what the dropped
--      trigger used to do for these two RPCs. NOT explicitly named by
--      task 11.1's four bullet points, but a NECESSARY consequence of
--      point 1 ("remittance_operations the sole write target") — leaving
--      these two untouched would have silently broken panel-driven
--      deposit verification and forced verification the moment the
--      bridge trigger was dropped, which is exactly the kind of silent
--      regression this task was told not to ship.
--   7. Repoints the one panel-facing view that still preferred
--      `deals.value` over `remittance_operations.quoted_source_amount`
--      (`cerebro_historial_operaciones`, 053 — the view that already
--      replaced the Kanban board for looking at the past, read by 088's
--      paginated history RPC) and its `cerebro_volumen_diario` sibling,
--      consistent with 113's precedent for `tasas`. Adjusts
--      `cerebro_conciliacion_operaciones` (041/063) so a panel-delivered
--      operation (whose deal no longer moves to Entregada, by design) is
--      not reported as a permanent false-positive divergence.
--
-- ---------------------------------------------------------------------
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT TOUCH
-- ---------------------------------------------------------------------
--
--   - `deals` rows are NEVER deleted, and `depositos_mmg.deal_id` linkage
--     is untouched — spec requirement "Deal Data Preserved", no data
--     loss (item 4 of the spec's remesa-operation-source-of-truth
--     capability).
--   - `deals.value`, `deals.currency`, `deals.notes` and the initial
--     `deals.stage_id` an n8n-created deal is born with are all still
--     written exactly as before. Only SUBSEQUENT `deals.stage_id` writes
--     (the ones that used to track a live operation's progress) are
--     removed — a deal is now "born" at some initial stage and stays
--     there historically, which is fine because nothing reads
--     `deals.stage_id` for anything live-tracking-related after this
--     migration (guard 12b and 052's auto-won/open flip both go
--     naturally INERT, exactly as the design's own File Changes/Object
--     table predicted — neither is touched here, there is nothing left
--     for either to react to).
--   - `trg_sync_z_benef_desde_deal` / `cerebro_sync_beneficiarios` /
--     `cerebro_sync_benef_trigger` (042/043) are completely untouched —
--     they key off `deals.notes`, which this migration never stops
--     writing.
--   - No n8n workflow is imported or modified here (11.5, human-only).
--   - No production migration-numbering reconciliation happens here
--     (1.1b/11.5, human-only) — see the KNOWN OPEN RISK note below.
--
-- ROLLBACK: see ROLLBACK-114-cutover-retire-sync-pipeline.sql, which
-- restores every function/trigger/view this migration replaces to its
-- immediately-prior (108/099/110/090/041-060/053/063) body verbatim.
--
-- KNOWN OPEN RISK, carried forward from apply-progress, NOT resolved
-- here and NOT this task's job to resolve: this repository's migration
-- numbering (095-113, now +114) has not been reconciled against the
-- separate "cerebro" series' live numbering in production, and none of
-- 103-114 are registered in `supabase_migrations.schema_migrations`.
-- Task 11.5's fingerprint compare (1.1a template) cannot rely on that
-- table and must be run, read, and resolved by a human against
-- production directly. This migration is authored and staging-validated
-- only; it is never applied to production by this task.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Capture the live `deals_stage_notify` trigger, then retire it in
--    favour of an equivalent relay on `remittance_operations`.
-- ---------------------------------------------------------------------
-- Body and trigger definition captured VERBATIM from the live catalog
-- (see gate-1.2 audit, Q2 — the same `pg_get_functiondef`/`pg_trigger`
-- read used to answer "does any workflow move a deal to Entregada").
-- This is the first time this drifted object is versioned in this
-- repository, matching 109/112's "capture, then modify" pattern. The
-- CREATE OR REPLACE below is a byte-identical no-op on any environment
-- that already has it; the DROP TRIGGER two statements later is the
-- actual behavior change.

CREATE OR REPLACE FUNCTION public.notify_deal_stage_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM net.http_post(
    url     := cerebro_config_get('notify_url'),
    body    := jsonb_build_object('type', 'UPDATE', 'table', 'deals',
                 'record', to_jsonb(NEW), 'old_record', to_jsonb(OLD)),
    headers := jsonb_build_object('Content-Type', 'application/json',
                 'X-Cerebro-Secret', cerebro_config_get('notify_secret')));
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.notify_deal_stage_change() IS
  'Captured verbatim by 114 from the live (previously unversioned) '
  'trigger function, immediately before its trigger (deals_stage_notify) '
  'was retired. Kept defined, unused, for historical/rollback reference '
  '— see 114''s ROLLBACK.';

DROP TRIGGER IF EXISTS deals_stage_notify ON deals;


-- The equivalent relay on remittance_operations. Deliberately as generic
-- as the original: ANY status change fires it (the original fired on
-- ANY stage_id change, and let the receiving n8n workflow decide what,
-- if anything, to tell the client by inspecting the payload). This keeps
-- the stage/status-specific customer-messaging decisions exactly where
-- they already lived — in n8n — rather than duplicating that judgment
-- call into Postgres. The workflow itself needs repointing to the new
-- payload shape ('table': 'remittance_operations', 'record'/'old_record'
-- shaped like a remittance_operations row instead of a deals row) —
-- that repoint ships with 11.5's "import n8n workflow" step, human-only.

CREATE OR REPLACE FUNCTION notify_operation_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM net.http_post(
    url     := cerebro_config_get('notify_url'),
    body    := jsonb_build_object('type', 'UPDATE', 'table', 'remittance_operations',
                 'record', to_jsonb(NEW), 'old_record', to_jsonb(OLD)),
    headers := jsonb_build_object('Content-Type', 'application/json',
                 'X-Cerebro-Secret', cerebro_config_get('notify_secret')));
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Same rule as every other trigger in this schema: a notification that
  -- fails to send must never abort the financial write it is reacting to.
  RAISE WARNING '[wacrm] notify_operation_status_change failed for operation % : %', NEW.id, SQLERRM;
  RETURN NEW;
END $$;

COMMENT ON FUNCTION notify_operation_status_change() IS
  '114. Replaces deals_stage_notify for the panel/n8n cutover: relays '
  'ANY remittance_operations.status change to the same notify_url/'
  'notify_secret webhook deals_stage_notify used, so the (separately '
  're-pointed, 11.5) n8n workflow can react to it the same way.';

DROP TRIGGER IF EXISTS trg_notify_operation_status_change ON remittance_operations;
CREATE TRIGGER trg_notify_operation_status_change
  AFTER UPDATE OF status ON remittance_operations
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION notify_operation_status_change();


-- ---------------------------------------------------------------------
-- 2. Retire `trg_notify_deal_incidencia` (090), port to
--    remittance_operations.status = 'incident'.
-- ---------------------------------------------------------------------
-- `notify_deal_incidencia()` (090) itself is untouched and stays defined
-- (unused after this) purely for historical/rollback reference — same
-- posture as every other retired trigger in this migration.

DROP TRIGGER IF EXISTS trg_notify_deal_incidencia ON deals;

COMMENT ON FUNCTION public.notify_deal_incidencia() IS
  '090. Retired by 114 (trigger dropped, function kept for rollback '
  'reference) — ported to notify_operation_incidencia() on '
  'remittance_operations.status = ''incident''.';


-- remittance_operations carries no free-text reason column (unlike
-- deals.notes). The reason text is read from the linked deal's notes
-- when one exists (deal_id linkage is preserved by this migration — see
-- header) using the exact same "last line of notes" extraction 090
-- used; when there is no linked deal, a generic reason is used instead
-- of silently dropping the alert.

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
  v_deal_notes text;
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

  IF NEW.deal_id IS NOT NULL THEN
    SELECT d.notes INTO v_deal_notes FROM deals d WHERE d.id = NEW.deal_id;
    v_motivo := NULLIF(trim(split_part(coalesce(v_deal_notes, ''), chr(10),
                  array_length(string_to_array(coalesce(v_deal_notes, ''), chr(10)), 1))), '');
  END IF;

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
  '114. Ports notify_deal_incidencia (090) onto remittance_operations. '
  'Reason text still comes from the linked deal''s notes (deal linkage '
  'is preserved) when one exists; falls back to a generic reason '
  'instead of dropping the alert when it does not.';

DROP TRIGGER IF EXISTS trg_notify_operation_incidencia ON remittance_operations;
CREATE TRIGGER trg_notify_operation_incidencia
  AFTER INSERT OR UPDATE OF status ON remittance_operations
  FOR EACH ROW
  EXECUTE FUNCTION notify_operation_incidencia();


-- ---------------------------------------------------------------------
-- 3. Retire the deals -> remittance_operations INSERT/UPDATE bridge;
--    keep a DELETE-only cancellation trigger (060's safety net).
-- ---------------------------------------------------------------------
-- The INSERT/UPDATE mirror direction is fully replaced by section 4
-- below (explicit writes inside the three n8n functions) and sections
-- 5/6 (explicit writes inside the three panel RPCs) — nothing is left
-- depending on trg_sync_operacion_desde_deal's INSERT/UPDATE branches by
-- the time this migration finishes applying. The DELETE branch (060 —
-- "deleting a deal cancels its live operation, instead of leaving it a
-- phantom open remittance shown to the customer forever") has no
-- equivalent anywhere else in this migration and is preserved verbatim.

DROP TRIGGER IF EXISTS trg_sync_operacion_desde_deal ON deals;

CREATE OR REPLACE FUNCTION cerebro_cancel_operacion_on_deal_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.pipeline_id IS DISTINCT FROM '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid THEN
    RETURN NULL;
  END IF;
  UPDATE remittance_operations
     SET status = 'cancelled', cancelled_at = now()
   WHERE deal_id = OLD.id
     AND status NOT IN ('completed', 'cancelled');
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] cancelar operacion fallo al borrar deal % : %', OLD.id, SQLERRM;
  RETURN NULL;
END $$;

COMMENT ON FUNCTION cerebro_cancel_operacion_on_deal_delete() IS
  '114. The DELETE-only half of cerebro_sync_operacion_desde_deal '
  '(041/043/060) — the ONLY half of that trigger this migration '
  'preserves. Deleting a deal still cancels its live (non-terminal) '
  'operation; the INSERT/UPDATE mirror direction is retired.';

DROP TRIGGER IF EXISTS trg_cancel_operacion_on_deal_delete ON deals;
CREATE TRIGGER trg_cancel_operacion_on_deal_delete
  AFTER DELETE ON deals
  FOR EACH ROW
  EXECUTE FUNCTION cerebro_cancel_operacion_on_deal_delete();


-- ---------------------------------------------------------------------
-- 4. cerebro_registrar_deposito / cerebro_cruzar_deposito /
--    cerebro_cruzar_depositos — stop writing deals.stage_id, make the
--    remittance_operations write self-sufficient (row creation +
--    quoted_source_amount/contact_id mirroring, not just status).
-- ---------------------------------------------------------------------
-- Bodies below are 110's bodies with EXACTLY these changes:
--   - the three UPDATE deals statements drop `stage_id = ...,` from
--     their SET list (value/currency/notes/updated_at unchanged);
--   - the brand-new-deal INSERT branch of cerebro_registrar_deposito
--     gains an explicit INSERT INTO remittance_operations, replacing
--     the row-creation half of the now-dropped bridge trigger;
--   - the "movido"/"sumado" UPDATE remittance_operations statements
--     (already present since 110, status-only) are extended to also set
--     quoted_source_amount/contact_id, replacing the mirroring half of
--     the now-dropped bridge trigger for those two branches.
-- Nothing else — idempotency, beneficiary/recarga/revendedor detection,
-- REFERENCIA IMPOSIBLE, the deposit cross-reference engine itself — is
-- touched.

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
  ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO NOTHING;

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
       SET notes = COALESCE(notes, '') || CASE WHEN v_nota = '' THEN '' ELSE chr(10) || v_nota END,
           updated_at = now()
     WHERE id = p_deal;
    GET DIAGNOSTICS v_tocados = ROW_COUNT;
    -- (114) deals.stage_id is no longer written here.
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
-- 5. crm_entregar_operacion (task 11.1 item 2) — drop the deal-stage
--    delivery gate, stop writing deals.stage_id, one UPDATE.
-- ---------------------------------------------------------------------
-- Body below is 108's (the LIVE definition — see 108's own header on why
-- it, not 101, is the byte-identical baseline) with these changes:
--   - the `v_stage IS DISTINCT FROM v_lista` half of the readiness check
--     is removed; gating is now solely
--     `remittance_operations.status = 'ready_to_transfer'`;
--   - the deal lock (`SELECT ... FROM deals ... FOR UPDATE`) is kept
--     (still useful: it preserves lock ordering against concurrent n8n
--     deals.notes/value writes, avoiding the deadlock risk the original
--     comment called out) but no longer reads/uses stage_id;
--   - `UPDATE deals SET stage_id = v_entregada ...` is removed entirely;
--   - the evidence UPDATE and the status UPDATE — previously two
--     statements straddling the deals UPDATE (108's own careful fix) —
--     are now ONE UPDATE on remittance_operations. This is strictly
--     safer than 108's reorder: a single statement cannot present the
--     calculator feed trigger with stale evidence columns, because
--     there is no second statement left to race against.

CREATE OR REPLACE FUNCTION crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id    uuid;
  v_deal_id       uuid;

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

  -- Lock the deal too (when there is one) to preserve ordering against
  -- concurrent n8n deals.notes/value writes — deal_id is no longer a
  -- hard requirement for delivery (item 1: remittance_operations is the
  -- sole write target), only a historical linkage.
  IF v_deal_id IS NOT NULL THEN
    PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;
  END IF;

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
  END IF;

  -- (114) One statement: status, evidence, completed_at (the latter set
  -- automatically by trg_remittance_operations_touch, 040) all land in
  -- the same NEW row image the calculator feed trigger reads.
  UPDATE remittance_operations
     SET status = 'completed',
         delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid()
   WHERE id = p_operation_id
     AND status = 'ready_to_transfer'
  RETURNING status, completed_at INTO v_status_after, v_completed_at;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer'),
          jsonb_build_object('status', 'completed', 'evidence', p_evidence));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $$;

REVOKE ALL ON FUNCTION crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_entregar_operacion(uuid, jsonb) TO authenticated;


-- ---------------------------------------------------------------------
-- 6. crm_verificar_deposito / crm_forzar_verificacion (099) — necessary
--    consequence of item 1 (see this migration's header, point 6).
-- ---------------------------------------------------------------------
-- Bodies below are 099's bodies with these changes:
--   - the secondary deal-stage gate (`SELECT stage_id ... FOR UPDATE` +
--     `IF v_stage NOT IN (...)`) is removed — it was already redundant
--     with the primary `v_status_before` gate, and would become WRONG
--     once deals.stage_id stops updating (item 4 above);
--   - the deal is still locked (`PERFORM 1 FROM deals ... FOR UPDATE`)
--     to preserve lock ordering, deals.notes rewrite is unchanged;
--   - `stage_id = ...` is dropped from both deals UPDATEs;
--   - an explicit `UPDATE remittance_operations SET status = ...`
--     replaces what the retired bridge trigger used to do.
-- crm_comprobantes_de_operacion (099, section 2) is read-only and
-- unaffected; NOT reproduced here (CREATE OR REPLACE would be a
-- byte-identical no-op).

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

  PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  -- Equivalent "current stage" for the legacy cross-reference engine's
  -- no-op-stage input contract (p_stage_ok = p_stage_incidencia =
  -- p_stage_esperado below): derived from remittance_operations.status,
  -- not read from deals.stage_id (114).
  v_stage := CASE v_status_before
               WHEN 'deposit_verification' THEN v_por_verificar
               WHEN 'incident'             THEN v_incidencia
             END;

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
         SET notes = replace(coalesce(notes, ''),
                              'VERIFICADO: casa con el correo de MMG',
                              'VERIFICADO EN PANEL: casa con el correo de MMG')
                     || chr(10) || 'VERIFICADO EN PANEL por un operador del CRM',
             updated_at = now()
       WHERE id = v_deal_id;
    ELSIF v_final <> v_stage THEN
      UPDATE deals SET updated_at = now() WHERE id = v_deal_id;
    END IF;

    IF v_final <> v_stage THEN
      -- (114) Direct write replacing the retired bridge trigger.
      UPDATE remittance_operations
         SET status = cerebro_estado_desde_etapa(v_final)
       WHERE id = p_operation_id;
    END IF;

    SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_deposit_verification',
            wacrm_current_actor(),
            jsonb_build_object('status', v_status_before),
            jsonb_build_object('status', v_status_after,
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
  v_account_id     uuid;
  v_status_before  text;
  v_status_after   text;
  v_deal_id        uuid;
  v_reason         text;
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

  PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  UPDATE deals
     SET notes = replace(coalesce(notes, ''),
                          'VERIFICADO: casa con el correo de MMG',
                          'VERIFICADO EN PANEL: casa con el correo de MMG')
                 || chr(10) || 'VERIFICACION FORZADA EN PANEL: ' || v_reason,
         updated_at = now()
   WHERE id = v_deal_id;

  -- (114) Direct write replacing the retired bridge trigger.
  UPDATE remittance_operations
     SET status = 'ready_to_transfer'
   WHERE id = p_operation_id;

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_forced_verification',
          wacrm_current_actor(), v_reason,
          jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', v_status_after));

  RETURN jsonb_build_object('new_status', v_status_after);
END $$;

REVOKE ALL ON FUNCTION crm_verificar_deposito(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_verificar_deposito(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION crm_forzar_verificacion(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_forzar_verificacion(uuid, text) TO authenticated;


-- ---------------------------------------------------------------------
-- 7. View repointing (task 11.1 item 4, consistent with 113's precedent)
-- ---------------------------------------------------------------------

-- cerebro_historial_operaciones (053) — the panel-facing history view
-- that already replaced looking at the Kanban board (088's paginated
-- history RPC reads it). Prefer remittance_operations.quoted_source_amount
-- (the now-authoritative, always-current source) over deals.value (which
-- stops updating for panel-only completions after this migration),
-- falling back to deals.value only when quoted_source_amount is NULL.

CREATE OR REPLACE VIEW cerebro_historial_operaciones AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  o.status,
  ct.name   AS cliente,
  ct.phone  AS telefono,
  coalesce(o.quoted_source_amount, d.value, 0) AS monto_gyd,
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

COMMENT ON VIEW cerebro_historial_operaciones IS
  '053, repointed by 114: prefers remittance_operations.quoted_source_amount '
  'over deals.value now that deals.stage_id/value stop tracking a live '
  'panel-completed operation. Row shape unchanged.';


-- cerebro_volumen_diario (053, feeds cerebro_resumen_volumen and
-- cerebro_volumen()) — same coalesce-order flip, same reasoning.

CREATE OR REPLACE VIEW cerebro_volumen_diario AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  count(*)                                                            AS operaciones,
  sum(coalesce(o.quoted_source_amount, d.value, 0))                   AS volumen_gyd,
  round(avg(coalesce(o.quoted_source_amount, d.value, 0)))            AS ticket_medio_gyd
FROM remittance_operations o
LEFT JOIN deals d ON d.id = o.deal_id
WHERE o.status = 'completed'
GROUP BY 1, 2;

COMMENT ON VIEW cerebro_volumen_diario IS
  '053, repointed by 114: same coalesce-order flip as '
  'cerebro_historial_operaciones, for the same reason.';


-- cerebro_conciliacion_operaciones (041/063) — an internal drift-audit
-- view, not itself panel/bot-facing, but its "estado divergente" branch
-- compares o.status against a mapping of d.stage_id. Since
-- crm_entregar_operacion (section 5) no longer moves the deal to
-- Entregada, EVERY panel-delivered operation would otherwise show up as
-- a permanent false-positive divergence from this migration onward —
-- delivery is human-only via the panel (spec: admin-field-ownership,
-- "Automation Cannot Perform Human-Only Actions"), so a completed
-- operation whose deal never reached Entregada is now the EXPECTED
-- shape, not a bug this view should keep flagging.

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
      ELSE 'collecting_information' END
    -- (114) A completed operation whose deal never moved to Entregada is
    -- the expected post-cutover shape for every panel delivery, not a
    -- divergence this audit view should keep reporting.
    AND o.status <> 'completed';

COMMENT ON VIEW cerebro_conciliacion_operaciones IS
  '041/063, repointed by 114: the estado-divergente branch excludes '
  'o.status = ''completed'', since a panel-delivered operation''s deal no '
  'longer moves to Entregada (crm_entregar_operacion, section 5) — that '
  'is now the expected shape, not drift.';

NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- VALIDATED ON STAGING (crm.onlinefreedom.site's isolated DB) — see
-- supabase/staging/assertions/cutover.sql (task 11.2) for the exact
-- fixtures and expectations: no dual-write into deals, the stage gate no
-- longer blocks delivery, Incidencia notification still fires, and the
-- repointed views read from remittance_operations.
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-114-cutover-retire-sync-pipeline.sql
-- =====================================================================
