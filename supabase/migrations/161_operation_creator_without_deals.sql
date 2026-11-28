-- =====================================================================
-- 161 — operation creator without deals
--
-- Until now the ONLY way a remittance_operations row was born was an
-- INSERT INTO deals, which fired trg_sync_operacion_al_crear_deal (125)
-- and let that trigger derive and create the operation. This migration
-- adds the replacement: a function that builds the operation directly,
-- deriving everything it can from the conversation, with no deals row
-- anywhere in the path.
--
-- Nothing calls it yet. WU5 rewires the n8n nodes; WU4b/WU4c build the
-- "envio nuevo creado" branches on top of it. This unit only adds and
-- proves the function.
--
-- ---------------------------------------------------------------------
-- SIGNATURE
-- ---------------------------------------------------------------------
--   cerebro_crear_operacion(
--     p_conversation_id uuid,
--     p_amount          numeric DEFAULT 0,
--     p_currency        text    DEFAULT 'GYD',
--     p_stage_id        uuid    DEFAULT '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109')
--   RETURNS uuid
--
-- Returns the new operation id.
--
-- The conversation is the only mandatory input: every later adapter
-- (the n8n "envio nuevo" branches, the panel RPCs) holds a conversation
-- id and nothing else about the operation it is about to create.
-- account_id and contact_id are NOT parameters on purpose — see
-- "ACCOUNT / CONTACT DERIVATION" below; letting a caller pass them in is
-- exactly how an orphan gets written, and the old path never took them
-- from the caller either (the deal row carried them, and the trigger
-- copied them across).
--
-- p_amount / p_currency mirror deals.value / deals.currency, the two
-- fields the caller used to put on the deal row. Defaults 0 / 'GYD' are
-- the values every n8n "envio nuevo" node currently writes.
--
-- p_stage_id mirrors deals.stage_id. It is fed through
-- cerebro_estado_desde_etapa (041) to produce the operation status, the
-- same helper the 125 trigger calls. It defaults to the pipeline's first
-- stage, "Solicitada" (96cd4fec), which is where every writer creates a
-- new deal today.
--
-- ---------------------------------------------------------------------
-- INITIAL STATUS: 'collecting_information'
-- ---------------------------------------------------------------------
-- Three independent lines of evidence agree, and all three are checked
-- against the live sources rather than assumed:
--
--   (a) It is the column default (040:43): a bare INSERT that named no
--       status would land on collecting_information. The 125 trigger
--       always names one, so this alone is not the proof.
--   (b) It is what cerebro_estado_desde_etapa (041:39) returns for
--       96cd4fec, the "Solicitada" stage — and ELSE in that same CASE
--       also returns collecting_information, so an unmapped stage
--       degrades to the same value rather than to NULL.
--   (c) Decisive: all six n8n writer nodes insert a new deal at
--       stage_id 96cd4fec with value 0 and currency 'GYD'. The 125
--       trigger therefore computes collecting_information for every
--       operation born from the live system, with no exception. The
--       default parameter values reproduce the same inputs, so the new
--       path lands on the same status by the same function.
--
-- ---------------------------------------------------------------------
-- ACCOUNT / CONTACT DERIVATION
-- ---------------------------------------------------------------------
-- conversations.account_id and conversations.contact_id, resolved by
-- the conversation id. Those are the same values the n8n nodes copy onto
-- the deal row — the nodes read
--   SELECT conv.user_id, conv.account_id, conv.contact_id
--     FROM conversations v JOIN contacts c ON c.id = v.contact_id
--    WHERE v.id = ...
-- and write them straight into deals.account_id / deals.contact_id. The
-- 125 trigger then copies them from NEW. So deriving from the
-- conversation reproduces the trigger's inputs exactly, field for field,
-- and the parity assertion below is what proves it rather than this
-- comment.
--
-- ---------------------------------------------------------------------
-- ORPHAN BEHAVIOUR: raise, never write a half-built row
-- ---------------------------------------------------------------------
-- remittance_operations has NO foreign key on deal_id, account_id or
-- conversation_id. A wrong id does not raise — it writes a row that
-- nothing will ever read, silently. So this function validates every id
-- it is about to write and raises instead:
--
--   * p_conversation_id IS NULL                      -> 22004
--   * conversation does not exist                    -> 23503
--   * resolved account_id IS NULL or not in accounts -> 23503
--   * resolved contact_id not in contacts            -> 23503
--
-- 23503 (foreign_key_violation) is chosen because that is the SQLSTATE
-- an equivalent real FK would have produced: callers that already handle
-- a missing parent get the same class of error they would from a
-- constraint, and a generic error handler will not mistake it for a
-- transient failure.
--
-- Returning NULL, or returning the id of a row that was not written, was
-- rejected: the 125 trigger swallows its own failures into a WARNING and
-- RETURNs NULL (nothing can be done from an AFTER INSERT trigger), and
-- that swallow is precisely why a missing operation can go unnoticed
-- today. A direct function has no such excuse and must fail loudly.
--
-- ---------------------------------------------------------------------
-- DELIBERATELY NOT DONE HERE
-- ---------------------------------------------------------------------
-- * No deals / pipelines / pipeline_stages read or write anywhere in this
--   file.
-- * cerebro_resolver_operacion(uuid, text[]) is not called: it exists on
--   staging but is absent from the working tree and all reachable git
--   history (drift documented at 097:38-53). Only the repo-visible
--   single-argument cerebro_resolver_operacion(uuid) is used, and only by
--   the assertion, not by this function.
-- * Beneficiaries are NOT written. The old path's trigger calls
--   cerebro_sync_beneficiarios(NEW.id), which parses the deal's notes
--   into remittance_beneficiaries. That function is deal-keyed and cannot
--   be called here — deal_id is NULL by design. Writing beneficiaries for
--   a deal-free operation is WU4b/WU4c scope. This is a REAL, KNOWN gap
--   between the two paths, recorded in the assertion's case 3 output
--   rather than hidden.
-- * No trigger is added. Nothing is dropped or redefined.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_crear_operacion(
  p_conversation_id uuid,
  p_amount          numeric DEFAULT 0,
  p_currency        text    DEFAULT 'GYD',
  p_stage_id        uuid    DEFAULT '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109'::uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
  v_contact_id uuid;
  v_status     text;
  v_op_id      uuid;
BEGIN
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'cerebro_crear_operacion: p_conversation_id is NULL; no operation created'
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  SELECT c.account_id, c.contact_id
    INTO v_account_id, v_contact_id
    FROM conversations c
   WHERE c.id = p_conversation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'cerebro_crear_operacion: conversation % does not exist; no operation created',
                    p_conversation_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_account_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id = v_account_id) THEN
    RAISE EXCEPTION 'cerebro_crear_operacion: conversation % resolves to account_id % which does not exist; no operation created',
                    p_conversation_id, v_account_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_contact_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM contacts ct WHERE ct.id = v_contact_id) THEN
    RAISE EXCEPTION 'cerebro_crear_operacion: conversation % resolves to contact_id % which does not exist; no operation created',
                    p_conversation_id, v_contact_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  v_status := cerebro_estado_desde_etapa(p_stage_id);

  INSERT INTO remittance_operations (
    account_id, conversation_id, contact_id, deal_id, status,
    service_type, quoted_source_amount, source_currency, created_at,
    completed_at, cancelled_at
  )
  VALUES (
    v_account_id, p_conversation_id, v_contact_id, NULL, v_status,
    'remesa', coalesce(p_amount, 0), coalesce(p_currency, 'GYD'), now(),
    CASE WHEN v_status = 'completed' THEN now() END,
    CASE WHEN v_status = 'cancelled' THEN now() END
  )
  RETURNING id INTO v_op_id;

  RETURN v_op_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_crear_operacion(uuid, numeric, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_crear_operacion(uuid, numeric, text, uuid)
  TO service_role;

NOTIFY pgrst, 'reload schema';
