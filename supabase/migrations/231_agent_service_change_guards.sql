-- =====================================================================
-- 231 -- The AGENT changes the service with a tool; the database only guards it (staging first)
--
-- odd/tasks/bot-change-service.md (Part D). Production 2026-10-08 (Carlos): cash USD quoted (162 USD), receipt sent, then "Mejor zelle".
-- Owner decision 2026-10-08: the first version of 231 detected "zelle" in the customer's words and switched the service. REJECTED as
-- fragile ("mi hermano usa zelle" would switch it): the agent must understand the context and ACT with a tool (cerebro_cambiar_servicio,
-- 230). This migration replaces that version (it was never applied to production) and contains ONLY the guards around the agent's tool:
--
-- a. cerebro_detectar_destino: NO Zelle and NO cash detection. It is 174's function plus ONE fix: a card rail (clasica / tropical / cup)
--    that the customer REJECTS in the turn is not a named rail. Before this fix (staging, pre-231 definition):
--      "no quiero clasica" -> clasica, "sin tropical" -> tropical, "no quiero cup" -> cuban_card, "clasica no" -> clasica.
--    Rejected = "no | ni | sin | nunca | tampoco | jamas | en vez de | en lugar de" followed by up to four words (none of pero / sino /
--    mejor / prefiero / entonces / ahora / y / e / another rail, and no comma) and then the rail; or the rail followed by "no" and a space; or the rail,
--    a comma and a bare "no" closing the sentence. When a rail is dropped and another one remains, the remaining one counts only if the
--    turn affirms it (it is written before the rejected rail: "tropical, no clasica"; or after it, past a comma or one of mejor / pero /
--    sino / prefiero / entonces / ahora / sea / quiero: "no quiero clasica, mejor tropical"); otherwise NULL ("no se si clasica o
--    tropical"). The positive detection and every input without a negation word are exactly 174's (proved by the assertion's table).
--    cerebro_registrar_destino and everything else of 157 are NOT touched: a Zelle / cash operation is never changed from text.
-- b. cerebro_destino_pendiente learns who wrote a row (origen: cliente = the customer's words through 157, agente = declared by the
--    cambiar_servicio tool) and the tipo CHECK accepts the five rails the tool takes (clasica, tropical, cuban_card, zelle, efectivo_usd).
--    cerebro_cambiar_servicio (230, same signature / grants / return shape, fields only added): when the conversation has NO operation yet
--    the AGENT-declared service is recorded as the pending destination (24 h, as 157) and the tool returns
--    {ok:true, changed:false, pendiente:true, servicio}. recarga / combo / visa / saldo get {ok:false, reason:'sin_operacion',
--    pendiente:false}: a pending service only makes sense for the remesa rails, because the operation that will be created is a remesa.
--    "No operation" includes "no OPEN operation": when the conversation's operations are all completed / cancelled (a repeat customer who
--    picks a service for the NEW remittance before it exists) the choice is recorded as pending too; estado_no_permite stays for an operation
--    that is open but forbids the change (transferring; incident is reached later and refused there).
--    A new AFTER INSERT trigger on remittance_operations applies a pending agent-declared service when a remesa is created without a rail and
--    it is the conversation's single open remesa, through the SAME core as the panel and the tool (audit row included), and consumes the
--    row. A per-conversation advisory lock taken by the tool and the trigger makes "pending written while the operation is being created"
--    race-free. A refusal at creation (human lock, ...) keeps the row. Nothing is ever sent to the customer.
-- c. cerebro_marcar_destino_usd (221 body + guards, same signature / grants / rows): (1) it refuses, writing nothing, when an
--    agent-declared pending service of the last 5 minutes differs from what it is asked to mark; (2) it refuses when the open operation's
--    rail was set by cerebro_cambiar_servicio (the delivery_method lock stamped automation:) and is a different rail; in the branch that
--    creates the operation itself it refuses to claim a rail the new operation did not get. Every refusal returns the 'ERROR: ...' row
--    naming the current choice. WHAT 230's LOCK ALREADY COVERED (probed on staging): a late marcar_destino_usd('efectivo') after a tool
--    change is suppressed by the 096 lock guard (WARNING + an automation_write_suppressed audit row) but the tool still answered
--    "destino marcado: entrega en USD por Efectivo" -- the agent was told the opposite of the truth; and it did not cover the
--    pending case at all (no operation yet). 231 adds the honest refusal and the pending case; it writes nothing on a refusal.
--    The calls are logged in tool_execution_log with an outcome (marcado | sin_cambios | rechazado | tipo_invalido | operacion_ambigua).
-- d. The safety net, for the end of every bot turn (n8n adds the call later):
--    cerebro_verificar_coherencia_servicio(conversation, execution) RETURNS jsonb. Evidence = only what the BOT did in that execution.
--    HONEST FINDING: the quote tools (calcular_usd_desde_gyd / calcular_usd / calcular_envio) wrote NO line in tool_execution_log and
--    cerebro_ultima_cotizacion keeps the amount and the tool name but NOT the via (one row per currency, overwritten). So the quoted
--    service was not recorded anywhere. cerebro_registrar_via_cotizada(conv, tool, via, execution, gyd) is the new, separate and
--    additive recorder (the 153 function is untouched): it logs one tool_execution_log line per quote (tool_name = the quote tool,
--    outcome = the normalised via), and the n8n quote queries must call it (plan Part D). Without that call the check finds no
--    quote and answers coherent: it never guesses a via from an amount.
--    Rule: take the LAST quote of the execution whose via is one of the five rails; if the conversation has a single open remesa
--    whose rail differs, and the execution has no successful cambiar_servicio / marcar_destino_usd to the quoted service, and no
--    agent-declared pending row for it -> ONE alert for the team (a notification per member, type coherencia_servicio) and
--    {coherente:false, cotizado, operacion, alert_id, operation_id}; otherwise {coherente:true, motivo}. HONEST LIMIT: a price
--    question ("¿y por zelle cuanto seria?") and a confirmed switch produce the same bot-side evidence (a quote for another rail,
--    no change call), so the rule cannot tell them apart; it takes the conservative path: a neutral text ("check whether the customer
--    switched"), at most one open alert per operation and pair of services, resolved (notifications marked read) by the next check
--    once the operation's rail is no longer the alerted one (they match, moved to a third rail, or no operation is open). notifications
--    has no priority column: the neutrality of the text is the "low priority". Nothing is changed and nothing reaches the customer.
-- e. Grants: service_role only (like cerebro_marcar_destino_usd); nothing to anon / authenticated / PUBLIC.
--
-- REMOVED from the first 231 (staging only): cerebro_registrar_destino_v2, cerebro_destino_es_pregunta (only the Zelle question filter
-- used it), cerebro_destino_pendiente_op_creada and trg_zz_destino_zelle_al_crear (keyword-fed creation trigger), the Zelle
-- branch of the detector and the e-mail filter. KEPT: cerebro_destino_riel_negado (the negation test), the origen column (new meaning).
-- Pre-231 md5 (pg_get_functiondef, staging 2026-10-08; ROLLBACK-231 restores exactly these): cerebro_detectar_destino 31f6d02d599b491c586284251b0502f9,
-- cerebro_registrar_destino c87c36beafde0cd256a601ee7290d045 (not touched), cerebro_marcar_destino_usd f239d898e9533b82a9822f4eb98ee6e7,
-- cerebro_cambiar_servicio f47c288efed9aa967a90c5487b08c166 (= 230).
-- Guarded by supabase/staging/assertions/agent-service-change-guards.sql. ROLLBACK: ROLLBACK-231-agent-service-change-guards.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. cerebro_destino_pendiente: the five rails, who wrote the row, which turn
-- ---------------------------------------------------------------------
ALTER TABLE public.cerebro_destino_pendiente DROP CONSTRAINT cerebro_destino_pendiente_tipo_check;
ALTER TABLE public.cerebro_destino_pendiente ADD CONSTRAINT cerebro_destino_pendiente_tipo_check
  CHECK (tipo = ANY (ARRAY['clasica'::text, 'tropical'::text, 'cuban_card'::text, 'zelle'::text, 'efectivo_usd'::text]));
ALTER TABLE public.cerebro_destino_pendiente ADD COLUMN IF NOT EXISTS origen text NOT NULL DEFAULT 'cliente'
  CHECK (origen IN ('cliente', 'agente'));
ALTER TABLE public.cerebro_destino_pendiente ADD COLUMN IF NOT EXISTS ejecucion text;
COMMENT ON COLUMN public.cerebro_destino_pendiente.origen IS
  '231. cliente = the destination the customer''s words named (cerebro_registrar_destino, 157); agente = declared by the agent through '
  'cerebro_cambiar_servicio before any operation existed. Only agente rows are applied to a new operation and guard marcar_destino_usd.';
COMMENT ON COLUMN public.cerebro_destino_pendiente.ejecucion IS '231. n8n execution of the turn that declared the service (agente rows).';

-- A row whose tipo is rewritten by anything but the agent tool is the customer's again.
CREATE OR REPLACE FUNCTION public.cerebro_destino_pendiente_origen()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.tipo IS DISTINCT FROM OLD.tipo AND coalesce(current_setting('wacrm.pendiente_origen', true), '') <> 'agente' THEN
    NEW.origen := 'cliente';
    NEW.ejecucion := NULL;
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS trg_destino_pendiente_origen ON public.cerebro_destino_pendiente;
CREATE TRIGGER trg_destino_pendiente_origen
  BEFORE UPDATE ON public.cerebro_destino_pendiente
  FOR EACH ROW EXECUTE FUNCTION public.cerebro_destino_pendiente_origen();
REVOKE ALL ON FUNCTION public.cerebro_destino_pendiente_origen() FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. The detector: 174's, plus the negation of the card rails
-- ---------------------------------------------------------------------
-- Folded text (lower case, no accents) expected. p_rail is a regex fragment.
CREATE OR REPLACE FUNCTION public.cerebro_destino_riel_negado(p_txt text, p_rail text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT
    -- "no quiero clasica", "ya no en CUP", "sin tropical", "en vez de clasica": a negator, up to four words, then the rail
    p_txt ~* ('(^|[^[:alnum:]])(no|ni|sin|nunca|tampoco|jamas|(vez|lugar)[[:space:]]+de)[[:space:]]+'
              || '(?:(?!(pero|sino|mejor|prefiero|entonces|ahora|y|e|clasicas?|tropical(es)?|cup|pesos)([^[:alnum:]]|$))[[:alnum:]]+[[:space:]]+){0,4}'
              || '(' || p_rail || ')([^[:alnum:]]|$)')
    -- "clasica no" (not when that "no" is followed by another rail: "tropical no clasica")
    OR p_txt ~* ('(^|[^[:alnum:]])(' || p_rail || ')[[:space:]]+no(?![[:alnum:]])'
                 || '(?![[:space:]]+(clasicas?|tropical(es)?|cup|pesos)([^[:alnum:]]|$))')
    -- "clasica, no."
    OR p_txt ~* ('(^|[^[:alnum:]])(' || p_rail || ')[[:space:]]*,[[:space:]]*no(?![[:alnum:]])[[:space:]]*([.!?;]|$)');
$function$;

-- The rail that stays (p_kept) is affirmed in a turn that rejected another one (p_dropped): written before the rejected rail, or after it
-- past a comma or an affirming word.
CREATE OR REPLACE FUNCTION public.cerebro_destino_riel_afirmado(p_txt text, p_kept text, p_dropped text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT p_txt ~* ('(^|[^[:alnum:]])(' || p_kept || ')(?![[:alnum:]]).*(^|[^[:alnum:]])(' || p_dropped || ')(?![[:alnum:]])')
      OR p_txt ~* ('(' || p_dropped || ')(?![[:alnum:]]).*(,|(^|[^[:alnum:]])(mejor|pero|sino|prefiero|entonces|ahora|sea|quiero)(?![[:alnum:]])).*'
                   || '(^|[^[:alnum:]])(' || p_kept || ')(?![[:alnum:]])');
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_detectar_destino(p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  c_cla      constant text := 'clasicas?';
  c_tro      constant text := 'tropical(es)?';
  c_cup      constant text := '(cup|pesos[[:space:]]+cubanos)';
  v_txt      text := coalesce(p_texto, '');
  v_fold     text := translate(lower(coalesce(p_texto, '')), 'áéíóúüÁÉÍÓÚÜ', 'aeiouuaeiouu');
  v_clasica  boolean;
  v_tropical boolean;
  v_cup      boolean;
  v_neg_cla  boolean;
  v_neg_tro  boolean;
  v_neg_cup  boolean;
  v_res      text;
BEGIN
  -- (174) Plurals too: "a unas tarjetas clasicas", "a las tropicales".
  v_clasica  := v_txt ~* '(^|[^[:alnum:]])cl[aáAÁ]sicas?([^[:alnum:]]|$)';
  v_tropical := v_txt ~* '(^|[^[:alnum:]])tropical(es)?([^[:alnum:]]|$)';
  v_cup      := v_txt ~* '(^|[^[:alnum:]])cup([^[:alnum:]]|$)'
             OR v_txt ~* '(^|[^[:alnum:]])pesos[[:space:]]+cubanos([^[:alnum:]]|$)';

  -- (231) A rail the customer rejects in the turn is not a named rail.
  v_neg_cla := v_clasica  AND cerebro_destino_riel_negado(v_fold, c_cla);
  v_neg_tro := v_tropical AND cerebro_destino_riel_negado(v_fold, c_tro);
  v_neg_cup := v_cup      AND cerebro_destino_riel_negado(v_fold, c_cup);
  v_clasica  := v_clasica  AND NOT v_neg_cla;
  v_tropical := v_tropical AND NOT v_neg_tro;
  v_cup      := v_cup      AND NOT v_neg_cup;

  IF v_clasica AND NOT v_tropical THEN
    v_res := 'clasica';
  ELSIF v_tropical AND NOT v_clasica THEN
    v_res := 'tropical';
  ELSIF v_cup AND NOT v_clasica AND NOT v_tropical THEN
    v_res := 'cuban_card';
  END IF;

  -- (231) A rail was rejected and another one remains: the remaining one must be affirmed, not merely left over.
  IF v_res IS NOT NULL AND (v_neg_cla OR v_neg_tro OR v_neg_cup) THEN
    IF NOT (
         (NOT v_neg_cla OR cerebro_destino_riel_afirmado(v_fold, CASE v_res WHEN 'clasica' THEN c_cla WHEN 'tropical' THEN c_tro ELSE c_cup END, c_cla))
     AND (NOT v_neg_tro OR cerebro_destino_riel_afirmado(v_fold, CASE v_res WHEN 'clasica' THEN c_cla WHEN 'tropical' THEN c_tro ELSE c_cup END, c_tro))
     AND (NOT v_neg_cup OR cerebro_destino_riel_afirmado(v_fold, CASE v_res WHEN 'clasica' THEN c_cla WHEN 'tropical' THEN c_tro ELSE c_cup END, c_cup))) THEN
      RETURN NULL;
    END IF;
  END IF;

  -- Both rails named, or nothing this function recognises.
  RETURN v_res;
END $function$;

COMMENT ON FUNCTION public.cerebro_detectar_destino(text) IS
  '157/174/231. clasica / tropical / cuban_card out of one turn of the customer''s text, or NULL when the turn names two rails or rejects '
  'the rail it names. IMMUTABLE: whole-word regexes, no table access. Zelle and cash are deliberately NOT detected: the agent decides '
  'them with cerebro_cambiar_servicio.';

REVOKE ALL ON FUNCTION public.cerebro_destino_riel_negado(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_destino_riel_afirmado(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_detectar_destino(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_destino_riel_negado(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_destino_riel_afirmado(text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_detectar_destino(text) TO service_role;

-- ---------------------------------------------------------------------
-- 3. Names of services (internal helper)
-- ---------------------------------------------------------------------
-- The canonical service for a free-form name the agent / the quote tools pass (cup -> cuban_card, efectivo -> efectivo_usd,
-- "Clásica" -> clasica); anything else comes back lower-cased and trimmed.
CREATE OR REPLACE FUNCTION public.cerebro_servicio_normalizar(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE v WHEN '' THEN NULL WHEN 'cup' THEN 'cuban_card' WHEN 'efectivo' THEN 'efectivo_usd' ELSE v END
    FROM (SELECT lower(btrim(translate(coalesce(p_texto, ''), 'áéíóúÁÉÍÓÚ', 'aeiouaeiou'))) AS v) s;
$function$;
REVOKE ALL ON FUNCTION public.cerebro_servicio_normalizar(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_servicio_normalizar(text) TO service_role;

-- ---------------------------------------------------------------------
-- 4. The quote's via, recorded per execution (separate and additive: 153's function is untouched)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_registrar_via_cotizada(
  p_conv uuid, p_herramienta text, p_via text, p_execution_id text, p_origen_gyd numeric DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_via  text := cerebro_servicio_normalizar(p_via);
  v_exec text := nullif(btrim(coalesce(p_execution_id, '')), '');
BEGIN
  -- No via, no execution, no conversation: no evidence, nothing to record. Never fails the quote tool.
  IF p_conv IS NULL OR v_via IS NULL OR v_exec IS NULL OR p_herramienta IS NULL THEN
    RETURN;
  END IF;
  BEGIN
    INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, arguments, outcome, created_at)
    VALUES (v_exec || ':cotizar:' || p_herramienta || ':' || md5(v_via || clock_timestamp()::text), p_herramienta, v_exec, p_conv,
            jsonb_build_array(to_jsonb(p_origen_gyd), to_jsonb(v_via)),
            CASE WHEN v_via IN ('zelle', 'clasica', 'tropical', 'cuban_card', 'efectivo_usd') THEN v_via ELSE 'otra_via' END,
            clock_timestamp());
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] cerebro_registrar_via_cotizada failed for conversation % (%): %', p_conv, SQLSTATE, SQLERRM;
  END;
END $function$;
COMMENT ON FUNCTION public.cerebro_registrar_via_cotizada(uuid, text, text, text, numeric) IS
  '231. One tool_execution_log line per quote the bot gives (tool_name = the quote tool, outcome = the quoted via). Evidence for '
  'cerebro_verificar_coherencia_servicio; nothing else reads it.';
REVOKE ALL ON FUNCTION public.cerebro_registrar_via_cotizada(uuid, text, text, text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_via_cotizada(uuid, text, text, text, numeric) TO service_role;

-- ---------------------------------------------------------------------
-- 5. The alert: a notification type, and a table that remembers which alert is open
-- ---------------------------------------------------------------------
ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (type IN (
  'conversation_assigned', 'deal_incidencia', 'mensaje_fallido', 'promo_etecsa', 'chat_atascado', 'ingesta_caida', 'deposito_sin_cruzar',
  'mensaje_perdido', 'envio_incompleto', 'pide_mlc', 'envio_sin_beneficiario', 'remesa_abierta_vieja', 'entrega_efectivo_lista',
  'coherencia_servicio'));

CREATE TABLE IF NOT EXISTS public.cerebro_alertas_coherencia (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id       uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id  uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  operation_id     uuid NOT NULL REFERENCES public.remittance_operations(id) ON DELETE CASCADE,
  cotizado         text NOT NULL,
  riel_operacion   text NOT NULL,
  ejecucion        text,
  notification_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
  creada_en        timestamptz NOT NULL DEFAULT now(),
  resuelta_en      timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS cerebro_alertas_coherencia_abierta_uq
  ON public.cerebro_alertas_coherencia (operation_id, cotizado, riel_operacion) WHERE resuelta_en IS NULL;
ALTER TABLE public.cerebro_alertas_coherencia ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cerebro_alertas_coherencia FROM anon, authenticated;
COMMENT ON TABLE public.cerebro_alertas_coherencia IS
  '231. One row per alert raised by cerebro_verificar_coherencia_servicio (the bot quoted a service the open operation is not on). '
  'At most one OPEN row per operation and pair of services; closed by the next check once the operation''s rail no longer is the alerted one.';

-- ---------------------------------------------------------------------
-- 6. cerebro_cambiar_servicio: 230 + the agent's declared service survives when no operation exists yet
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_cambiar_servicio(p_conversation_id uuid, p_servicio text, p_execution_id text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_actor      constant text := 'automation:cerebro_cambiar_servicio';
  v_raw        text := lower(btrim(coalesce(p_servicio, '')));
  v_servicio   text;
  v_ids        uuid[];
  v_op         uuid;
  v_o          remittance_operations%ROWTYPE;
  v_status     text;
  v_actual     text;
  v_key        text;
  v_core       jsonb;
  v_result     jsonb;
  v_min        numeric;
  v_n          integer;
  v_prev       jsonb;
  v_prev_origin text;
  v_prev_actor  text;
  v_campo      text;
BEGIN
  v_servicio := CASE v_raw WHEN 'cup' THEN 'cuban_card' WHEN 'efectivo' THEN 'efectivo_usd' ELSE v_raw END;

  <<flow>>
  BEGIN
    IF v_servicio NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'servicio_desconocido');
      EXIT flow;
    END IF;

    -- (231) One writer at a time per conversation between this tool and the creation of an operation (the AFTER INSERT trigger takes the
    -- same lock): "pending written while the operation is being created" cannot be lost. Held to the end of the transaction.
    PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_destino_pendiente:' || p_conversation_id::text, 0));

    -- The conversation's open operation, the way the bot's other writers find it.
    SELECT coalesce(array_agg(o.id ORDER BY o.created_at), ARRAY[]::uuid[]) INTO v_ids
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer', 'incident');
    IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
      -- (231) No OPEN operation. Only an operation that is open but in a state that forbids the change (transferring) refuses; a completed /
      -- cancelled one (a repeat customer) is "no operation": the choice is for the NEW remittance and is recorded below.
      SELECT o.id, o.status INTO v_op, v_status
        FROM remittance_operations o WHERE o.conversation_id = p_conversation_id AND o.status = 'transferring' ORDER BY o.created_at DESC LIMIT 1;
      IF v_op IS NULL THEN
        IF v_servicio IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd')
           AND EXISTS (SELECT 1 FROM conversations c WHERE c.id = p_conversation_id) THEN
          -- (231) No operation yet (the customer says "mejor zelle" before the receipt turn creates it): the agent's declared service is
          -- the conversation's pending destination; the operation that is created next takes it (cerebro_destino_agente_al_crear).
          PERFORM set_config('wacrm.pendiente_origen', 'agente', true);
          INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen, ejecucion)
          VALUES (p_conversation_id, v_servicio, now(), 'agente', nullif(btrim(coalesce(p_execution_id, '')), ''))
          ON CONFLICT (conversation_id) DO UPDATE
             SET tipo = EXCLUDED.tipo, actualizado = EXCLUDED.actualizado, origen = 'agente', ejecucion = EXCLUDED.ejecucion;
          PERFORM set_config('wacrm.pendiente_origen', '', true);
          v_result := jsonb_build_object('ok', true, 'changed', false, 'pendiente', true, 'servicio', v_servicio);
        ELSE
          -- recarga / combo / visa / saldo are not remesa rails: nothing to declare ahead of the operation.
          v_result := jsonb_build_object('ok', false, 'reason', 'sin_operacion', 'pendiente', false);
        END IF;
      ELSE
        v_result := jsonb_build_object('ok', false, 'reason', 'estado_no_permite', 'status', v_status, 'operation_id', v_op);
      END IF;
      EXIT flow;
    END IF;
    IF array_length(v_ids, 1) > 1 THEN
      -- The same hand-over as cerebro_marcar_destino_usd: several open operations need a person.
      SELECT count(*) INTO v_n FROM cerebro_registrar_derivacion(
        p_conversation_id, 'Hay varias operaciones abiertas y el caso requiere revisión humana.', 'operacion_ambigua', true);
      v_result := jsonb_build_object('ok', false, 'reason', 'operacion_ambigua', 'derivado', v_n > 0);
      EXIT flow;
    END IF;
    v_op := v_ids[1];

    -- Same row lock as the panel; the status is read again under it.
    SELECT * INTO v_o FROM remittance_operations WHERE id = v_op FOR UPDATE;
    IF v_o.status NOT IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer') THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'estado_no_permite', 'status', v_o.status, 'operation_id', v_op);
      EXIT flow;
    END IF;
    IF v_o.service_type NOT IN ('remesa', 'recarga', 'combo', 'visa', 'saldo') THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'tipo_no_soportado', 'service_type', v_o.service_type, 'operation_id', v_op);
      EXIT flow;
    END IF;

    -- (231) The operation exists: a pending service the agent declared earlier has done its job, and must not stand in for the operation's
    -- rail (cerebro_riel_op falls back to the pending row when the operation has no rail yet).
    DELETE FROM cerebro_destino_pendiente WHERE conversation_id = p_conversation_id AND origen = 'agente';

    v_actual := cerebro_riel_op(v_op);
    v_prev := jsonb_build_object('servicio', v_actual, 'destination_amount', v_o.quoted_destination_amount,
                                 'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate);
    IF v_actual IS NOT DISTINCT FROM v_servicio THEN
      v_result := jsonb_build_object('ok', true, 'changed', false, 'operation_id', v_op, 'servicio', v_servicio,
                                     'source_amount_gyd', v_o.quoted_source_amount, 'destination_amount', v_o.quoted_destination_amount,
                                     'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate,
                                     'status', v_o.status);
      EXIT flow;
    END IF;

    -- A human fixed it: leave it to the team. A lock the automation itself left does not count.
    SELECT k INTO v_campo
      FROM unnest(ARRAY['delivery_method', 'service_type', 'quoted_destination_amount']) AS k
     WHERE coalesce(v_o.admin_locked_fields, '{}'::jsonb) ? k
       AND coalesce(v_o.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'automation:%'
     LIMIT 1;
    IF v_campo IS NOT NULL THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'bloqueado_por_humano', 'campo', v_campo, 'operation_id', v_op);
      EXIT flow;
    END IF;

    -- The change, with the minimum of the NEW service checked on the changed operation; a failure rolls the sub-block back.
    v_prev_origin := coalesce(current_setting('wacrm.origin', true), '');
    v_prev_actor  := coalesce(current_setting('wacrm.actor', true), '');
    BEGIN
      PERFORM set_config('wacrm.origin', 'admin', true);
      PERFORM set_config('wacrm.actor', c_actor, true);
      v_core := _cambiar_servicio_core(v_op, v_servicio, 'automation_service_change', c_actor,
                                       'n8n execution ' || coalesce(nullif(btrim(p_execution_id), ''), 'unknown'));
      PERFORM set_config('wacrm.origin', v_prev_origin, true);
      PERFORM set_config('wacrm.actor', v_prev_actor, true);
      SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
      v_min := cerebro_minimo_gyd(v_op);
      IF coalesce(v_o.quoted_source_amount, 0) > 0 AND v_min IS NOT NULL AND v_o.quoted_source_amount < v_min THEN
        RAISE EXCEPTION '%', v_min USING ERRCODE = 'WC230';
      END IF;
    EXCEPTION
      WHEN SQLSTATE 'WC230' THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        v_result := jsonb_build_object('ok', false, 'reason', 'por_debajo_del_minimo', 'servicio', v_servicio, 'operation_id', v_op,
                                       'minimo_gyd', SQLERRM::numeric, 'source_amount_gyd', v_o.quoted_source_amount);
      WHEN SQLSTATE '22023' THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        IF SQLERRM NOT LIKE 'several recipients%' THEN RAISE; END IF;
        v_result := jsonb_build_object('ok', false, 'reason', 'varios_destinatarios', 'operation_id', v_op);
      WHEN OTHERS THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        RAISE;
    END;
    IF v_result IS NOT NULL THEN
      EXIT flow;
    END IF;

    SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
    v_result := jsonb_build_object('ok', true, 'changed', true, 'operation_id', v_op, 'servicio', v_servicio,
                                   'source_amount_gyd', v_o.quoted_source_amount, 'destination_amount', v_o.quoted_destination_amount,
                                   'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate,
                                   'previous', v_prev,
                                   'retired_recipients', jsonb_array_length(v_core -> 'retired'),
                                   'retyped_recipients', jsonb_array_length(v_core -> 'retyped'),
                                   'status', v_o.status);
  END;

  v_key := coalesce(nullif(btrim(p_execution_id), ''), gen_random_uuid()::text) || ':cambiar_servicio:' || md5(coalesce(v_servicio, ''));
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
  VALUES (v_key, 'cambiar_servicio', p_execution_id, p_conversation_id, v_op, jsonb_build_array(to_jsonb(p_servicio)),
          CASE WHEN (v_result ->> 'ok')::boolean THEN
                 CASE WHEN coalesce((v_result ->> 'pendiente')::boolean, false) THEN 'pendiente'
                      WHEN (v_result ->> 'changed')::boolean THEN 'changed' ELSE 'unchanged' END
               ELSE v_result ->> 'reason' END)
  ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN v_result;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_cambiar_servicio(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_cambiar_servicio(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------
-- 7. A remesa created while the agent's declared service is pending takes it
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_destino_agente_al_crear()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_p   cerebro_destino_pendiente%ROWTYPE;
  v_res jsonb;
BEGIN
  IF NEW.conversation_id IS NULL THEN
    RETURN NULL;
  END IF;
  -- The same lock the tool takes before it decides whether an operation exists.
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_destino_pendiente:' || NEW.conversation_id::text, 0));
  SELECT * INTO v_p FROM cerebro_destino_pendiente p
   WHERE p.conversation_id = NEW.conversation_id AND p.origen = 'agente' AND p.actualizado > now() - interval '24 hours';
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  -- Only when this is the conversation's single open remesa (never a hand-over from a trigger).
  IF (SELECT count(*) FROM remittance_operations o
       WHERE o.conversation_id = NEW.conversation_id AND o.service_type = 'remesa' AND o.status NOT IN ('completed', 'cancelled')) <> 1 THEN
    RETURN NULL;
  END IF;
  BEGIN
    -- Taken away while the engine decides: cerebro_riel_op would otherwise read it as the operation's current rail.
    DELETE FROM cerebro_destino_pendiente WHERE conversation_id = NEW.conversation_id;
    v_res := cerebro_cambiar_servicio(NEW.conversation_id, v_p.tipo, 'pendiente:' || coalesce(v_p.ejecucion, 'unknown'));
    IF NOT coalesce((v_res ->> 'ok')::boolean, false) THEN
      -- Refused (a lock, a status, ...): the declaration stays for 24 h.
      PERFORM set_config('wacrm.pendiente_origen', 'agente', true);
      INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen, ejecucion)
      VALUES (v_p.conversation_id, v_p.tipo, v_p.actualizado, v_p.origen, v_p.ejecucion)
      ON CONFLICT (conversation_id) DO NOTHING;
      PERFORM set_config('wacrm.pendiente_origen', '', true);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] pending service % not applied to new operation % (%): %', v_p.tipo, NEW.id, SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END $function$;

DROP TRIGGER IF EXISTS trg_zz_destino_agente_al_crear ON public.remittance_operations;
CREATE TRIGGER trg_zz_destino_agente_al_crear
  AFTER INSERT ON public.remittance_operations
  FOR EACH ROW
  WHEN (NEW.service_type = 'remesa' AND NEW.delivery_method IS NULL AND NEW.status NOT IN ('completed', 'cancelled'))
  EXECUTE FUNCTION public.cerebro_destino_agente_al_crear();
REVOKE ALL ON FUNCTION public.cerebro_destino_agente_al_crear() FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 8. cerebro_marcar_destino_usd -- 221's body + the stale-write guard
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_marcar_destino_usd(p_conversation_id uuid, p_tipo text, p_execution_id text)
 RETURNS TABLE(id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Procedural, not a single CTE chain, for one concrete reason: the
-- `ins` branch must set delivery_method on the operation it has JUST
-- created, and every statement in one WITH chain shares one snapshot, so
-- an UPDATE cannot see the row inserted by cerebro_crear_operacion() in
-- the same statement. Two statements are needed, so the branches are
-- sequenced explicitly. The branch order and the emitted rows are exactly
-- the node's union order: falta, upd, ins, sin_cambio, ambiguo — with the
-- one multi-row case the node has (an invalid tipo AND two open
-- operations emits falta + ambiguo) preserved.
DECLARE
  v_resultado text;
  v_op        uuid;
  v_k         text;
  v_reg       integer;
  v_t         text;
  v_marker    text;
  v_actual    text;
  v_ben       text;
  v_nuevo     uuid;
  v_pend      text;
  v_lock_by   text;
  v_dm_nuevo  text;
BEGIN
  -- Inlined cerebro_resolver_operacion(uuid, text[]): see the header.
  SELECT CASE WHEN count(*) = 0 THEN 'ninguna'
              WHEN count(*) = 1 THEN 'unica'
              ELSE 'ambigua' END,
         CASE WHEN count(*) = 1
              THEN (SELECT o.id FROM remittance_operations o
                     WHERE o.conversation_id = p_conversation_id
                       AND o.status NOT IN ('completed','cancelled')
                       AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])
                     LIMIT 1)
         END
    INTO v_resultado, v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.status NOT IN ('completed','cancelled')
     AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);

  v_k := p_execution_id || ':marcar_destino_usd:' || md5(coalesce(p_tipo,''));
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT v_k, 'marcar_destino_usd', p_execution_id, p_conversation_id, v_op,
         jsonb_build_array(to_jsonb(p_tipo::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING 1 INTO v_reg;

  v_t := CASE WHEN lower(p_tipo) LIKE 'trop%' THEN 'Tropical'
              WHEN lower(p_tipo) LIKE 'cl%'   THEN 'Clasica'
              WHEN lower(p_tipo) LIKE 'efec%' THEN 'Efectivo' END;
  -- 151 line 77: the notes marker the trigger turns into delivery_method is
  -- lower(t) for Clasica/Tropical and the literal 'efectivo_usd' for
  -- Efectivo. Same expression the old trigger's UPDATE used.
  v_marker := CASE WHEN v_t = 'Efectivo'      THEN 'efectivo_usd'
                   WHEN v_t IS NOT NULL       THEN lower(v_t) END;

  -- falta
  IF v_t IS NULL THEN
    UPDATE tool_execution_log SET outcome = 'tipo_invalido' WHERE idempotency_key = v_k;
    RETURN QUERY SELECT NULL::uuid AS id,
      'ERROR: el tipo debe ser clasica, tropical o efectivo. No se marco nada.'::text AS accion;
  END IF;

  IF v_t IS NOT NULL THEN
    -- (231) Stale-write guard 1. The agent declared another service in the last 5 minutes (cerebro_cambiar_servicio with no operation
    -- yet): a model that marks a rail from chat memory is older than that decision. Write nothing, say which one stands.
    SELECT p.tipo INTO v_pend
      FROM cerebro_destino_pendiente p
     WHERE p.conversation_id = p_conversation_id
       AND p.origen = 'agente'
       AND p.actualizado > now() - interval '5 minutes';
    IF v_pend IS NOT NULL AND v_pend IS DISTINCT FROM v_marker THEN
      UPDATE tool_execution_log SET outcome = 'rechazado' WHERE idempotency_key = v_k;
      RETURN QUERY SELECT NULL::uuid AS id,
        ('ERROR: ya elegiste ' ||
         CASE v_pend WHEN 'zelle' THEN 'Zelle' WHEN 'cuban_card' THEN 'CUP (tarjeta en pesos)' WHEN 'clasica' THEN 'Clasica' WHEN 'efectivo_usd' THEN 'Efectivo' ELSE 'Tropical' END ||
         ' para este cliente con cambiar_servicio y ahora intentas marcar ' || v_t ||
         '. No se marco nada. La via vigente es la que elegiste; si el cliente pide otra, usa cambiar_servicio.')::text AS accion;
      RETURN;
    END IF;

    -- (231) Stale-write guard 2. The open operation's rail was set by cerebro_cambiar_servicio (the lock stamped automation:) and this is a
    -- different rail. The 096 lock would suppress the write anyway, but this tool used to answer "destino marcado" -- the opposite of the truth.
    IF v_op IS NOT NULL THEN
      SELECT o.admin_locked_fields #>> '{delivery_method,by}', coalesce(nullif(o.delivery_method, ''), cerebro_riel_op(o.id))
        INTO v_lock_by, v_actual
        FROM remittance_operations o WHERE o.id = v_op;
      IF coalesce(v_lock_by, '') LIKE 'automation:%' AND v_actual IS DISTINCT FROM v_marker THEN
        UPDATE tool_execution_log SET outcome = 'rechazado' WHERE idempotency_key = v_k;
        RETURN QUERY SELECT NULL::uuid AS id,
          ('ERROR: la via vigente de la operacion es ' ||
           CASE v_actual WHEN 'zelle' THEN 'Zelle' WHEN 'cuban_card' THEN 'CUP (tarjeta en pesos)' WHEN 'clasica' THEN 'Clasica' WHEN 'efectivo_usd' THEN 'Efectivo' WHEN 'tropical' THEN 'Tropical' ELSE coalesce(v_actual, 'otra') END ||
           ' (la cambiaste con cambiar_servicio) y ahora intentas marcar ' || v_t ||
           '. No se marco nada. Si el cliente pide otra via, usa cambiar_servicio.')::text AS accion;
        RETURN;
      END IF;
    END IF;
  END IF;

  -- abierto: upd / sin_cambio (both need an operation, and a rail)
  IF v_op IS NOT NULL THEN
    IF v_t IS NOT NULL THEN
      SELECT o.delivery_method,
             (SELECT b.beneficiary_type FROM remittance_beneficiaries b
               WHERE b.operation_id = o.id AND b.status = 'vigente'
               LIMIT 1)
        INTO v_actual, v_ben
        FROM remittance_operations o WHERE o.id = v_op;

      -- 'ENTREGA EN USD: <t>' in deals.notes becomes delivery_method = marker(t).
      IF coalesce(v_actual = v_marker, false) THEN
        -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
        END IF;
        UPDATE tool_execution_log SET outcome = 'sin_cambios' WHERE idempotency_key = v_k;
        RETURN QUERY SELECT v_op AS id,
          'sin cambios: ese destino ya estaba marcado'::text AS accion;
      ELSE
        UPDATE remittance_operations o
           SET delivery_method = coalesce(v_marker, v_ben, o.delivery_method)
         WHERE o.id = v_op
           AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, v_ben, o.delivery_method);
        -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
        END IF;
        UPDATE tool_execution_log SET outcome = 'marcado' WHERE idempotency_key = v_k;
        RETURN QUERY SELECT v_op AS id,
          ('destino marcado: entrega en USD por ' || v_t)::text AS accion;
      END IF;
    END IF;
    RETURN;
  END IF;

  -- no operation: ambiguo, or the node's `ins`
  IF v_resultado = 'ambigua' THEN
    UPDATE tool_execution_log SET outcome = 'operacion_ambigua' WHERE idempotency_key = v_k;
    RETURN QUERY
    SELECT NULL::uuid AS id,
           'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text AS accion
      FROM cerebro_registrar_derivacion(
             p_conversation_id,
             'Hay varias operaciones abiertas y el caso requiere revisión humana.',
             'operacion_ambigua',
             true) d;
  ELSIF v_t IS NOT NULL THEN
    v_nuevo := cerebro_crear_operacion(p_conversation_id);
    -- (231) The new operation may already have a rail: the agent's pending service is applied by the creation trigger. Do not write a
    -- different one over it, and do not claim it.
    SELECT o.delivery_method INTO v_dm_nuevo FROM remittance_operations o WHERE o.id = v_nuevo;
    IF v_dm_nuevo IS NOT NULL AND v_dm_nuevo IS DISTINCT FROM v_marker THEN
      UPDATE tool_execution_log SET outcome = 'rechazado' WHERE idempotency_key = v_k;
      RETURN QUERY SELECT v_nuevo AS id,
        ('ERROR: se creo el envio pero su via ya es ' ||
         CASE v_dm_nuevo WHEN 'zelle' THEN 'Zelle' WHEN 'cuban_card' THEN 'CUP (tarjeta en pesos)' WHEN 'clasica' THEN 'Clasica' WHEN 'efectivo_usd' THEN 'Efectivo' ELSE 'Tropical' END ||
         ' (la elegiste con cambiar_servicio) y no se marco ' || v_t || '. Si el cliente pide otra via, usa cambiar_servicio.')::text AS accion;
      RETURN;
    END IF;
    UPDATE remittance_operations o
       SET delivery_method = coalesce(v_marker, o.delivery_method)
     WHERE o.id = v_nuevo
       AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, o.delivery_method);
    -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
    IF v_t IN ('Clasica', 'Tropical') THEN
      PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
    END IF;
    UPDATE tool_execution_log SET outcome = 'marcado' WHERE idempotency_key = v_k;
    RETURN QUERY SELECT v_nuevo AS id,
      ('envio nuevo creado, entrega en USD por ' || v_t)::text AS accion;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_marcar_destino_usd(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_marcar_destino_usd(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------
-- 9. The safety net
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_verificar_coherencia_servicio(p_conversation_id uuid, p_execution_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  c_rieles  constant text[] := ARRAY['zelle', 'clasica', 'tropical', 'cuban_card', 'efectivo_usd'];
  v_exec    text := nullif(btrim(coalesce(p_execution_id, '')), '');
  v_ids     uuid[];
  v_op      uuid;
  v_o       remittance_operations%ROWTYPE;
  v_riel    text;
  v_cot     text;
  v_n       integer := 0;
  v_alert   uuid;
  v_nids    uuid[];
  v_new     boolean := false;
  v_nombre  jsonb := jsonb_build_object('zelle', 'Zelle', 'clasica', 'tarjeta Clásica', 'tropical', 'tarjeta Tropical',
                                        'cuban_card', 'CUP (tarjeta en pesos)', 'efectivo_usd', 'Efectivo en USD');
BEGIN
  IF p_conversation_id IS NULL THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_conversacion', 'resueltas', 0);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_coherencia:' || p_conversation_id::text, 0));

  SELECT coalesce(array_agg(o.id ORDER BY o.created_at), ARRAY[]::uuid[]) INTO v_ids
    FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.status IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer', 'incident');

  -- No open operation: an alert left from before has nothing to talk about any more.
  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
    v_n := cerebro_coherencia_resolver(p_conversation_id, NULL, NULL);
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_operacion', 'resueltas', v_n);
  END IF;
  IF array_length(v_ids, 1) > 1 THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'operacion_ambigua', 'resueltas', 0);
  END IF;
  v_op := v_ids[1];
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'remesa' THEN
    v_n := cerebro_coherencia_resolver(p_conversation_id, NULL, NULL);
    RETURN jsonb_build_object('coherente', true, 'motivo', 'no_remesa', 'resueltas', v_n);
  END IF;

  v_riel := cerebro_riel_op(v_op);
  -- An open alert whose pair no longer holds (the rails match, or the operation moved to a third rail) is closed.
  v_n := cerebro_coherencia_resolver(p_conversation_id, v_op, v_riel);

  IF v_exec IS NULL THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_ejecucion', 'resueltas', v_n);
  END IF;
  IF v_riel IS NULL OR NOT (v_riel = ANY (c_rieles)) THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_riel', 'resueltas', v_n);
  END IF;

  -- The LAST quote the bot gave in this execution (its via was recorded by cerebro_registrar_via_cotizada).
  SELECT t.outcome INTO v_cot
    FROM tool_execution_log t
   WHERE t.execution_id = v_exec AND t.conversation_id = p_conversation_id
     AND t.tool_name IN ('calcular_usd_desde_gyd', 'calcular_usd', 'calcular_envio', 'calcular_inverso')
   ORDER BY t.created_at DESC, t.id DESC
   LIMIT 1;
  IF v_cot IS NULL OR NOT (v_cot = ANY (c_rieles)) THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_cotizacion', 'resueltas', v_n);
  END IF;
  IF v_cot = v_riel THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'misma_via', 'resueltas', v_n);
  END IF;

  -- The bot acted on what it quoted: a successful change / mark to that service in this execution ...
  IF EXISTS (SELECT 1 FROM tool_execution_log t
              WHERE t.execution_id = v_exec AND t.conversation_id = p_conversation_id
                AND ((t.tool_name = 'cambiar_servicio' AND t.outcome IN ('changed', 'unchanged'))
                  OR (t.tool_name = 'marcar_destino_usd' AND t.outcome IN ('marcado', 'sin_cambios')))
                AND cerebro_servicio_normalizar(t.arguments ->> 0) = v_cot) THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'via_confirmada', 'resueltas', v_n);
  END IF;
  -- ... or declared it for the operation that does not exist yet.
  IF EXISTS (SELECT 1 FROM cerebro_destino_pendiente p
              WHERE p.conversation_id = p_conversation_id AND p.origen = 'agente' AND p.tipo = v_cot
                AND p.actualizado > now() - interval '24 hours') THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'via_declarada', 'resueltas', v_n);
  END IF;

  -- Quoted one service, the operation is on another, nothing was done about it: one alert per operation and pair.
  SELECT a.id INTO v_alert FROM cerebro_alertas_coherencia a
   WHERE a.operation_id = v_op AND a.cotizado = v_cot AND a.riel_operacion = v_riel AND a.resuelta_en IS NULL;
  IF v_alert IS NULL THEN
    WITH n AS (
      INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
      SELECT v_o.account_id, p.user_id, 'coherencia_servicio', p_conversation_id, v_o.contact_id,
             'Revisar servicio: el bot cotizó ' || (v_nombre ->> v_cot) || ' y la operación está en ' || (v_nombre ->> v_riel),
             'En esta conversación el bot cotizó ' || (v_nombre ->> v_cot) || ', pero la operación sigue en ' || (v_nombre ->> v_riel) ||
             '. Puede haber sido solo una consulta de precio. Revise si el cliente cambió de servicio y, si es así, cámbielo en el panel. ' ||
             'El bot no cambió nada y no escribió al cliente por este aviso.'
        FROM profiles p
       WHERE p.account_id = v_o.account_id
         AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id)
      RETURNING id)
    SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_nids FROM n;
    INSERT INTO cerebro_alertas_coherencia (account_id, conversation_id, operation_id, cotizado, riel_operacion, ejecucion, notification_ids)
    VALUES (v_o.account_id, p_conversation_id, v_op, v_cot, v_riel, v_exec, v_nids)
    RETURNING id INTO v_alert;
    v_new := true;
  END IF;

  RETURN jsonb_build_object('coherente', false, 'cotizado', v_cot, 'operacion', v_riel, 'alert_id', v_alert,
                            'operation_id', v_op, 'nueva', v_new, 'resueltas', v_n);
END $function$;

-- Closes the conversation's open alerts that no longer describe the operation (internal; p_op NULL = no open operation).
CREATE OR REPLACE FUNCTION public.cerebro_coherencia_resolver(p_conversation_id uuid, p_op uuid, p_riel text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_ids uuid[];
  v_n   integer;
BEGIN
  WITH r AS (
    UPDATE cerebro_alertas_coherencia a
       SET resuelta_en = now()
     WHERE a.conversation_id = p_conversation_id AND a.resuelta_en IS NULL
       AND (p_op IS NULL OR a.operation_id <> p_op OR a.riel_operacion IS DISTINCT FROM p_riel)
    RETURNING a.notification_ids)
  SELECT coalesce(array_agg(x), ARRAY[]::uuid[]), (SELECT count(*) FROM r)::integer INTO v_ids, v_n
    FROM (SELECT unnest(notification_ids) AS x FROM r) s;
  UPDATE notifications SET read_at = coalesce(read_at, now()) WHERE id = ANY (v_ids);
  RETURN coalesce(v_n, 0);
END $function$;

COMMENT ON FUNCTION public.cerebro_verificar_coherencia_servicio(uuid, text) IS
  '231. End-of-turn safety net: if the bot''s last quote of this execution is for a service the conversation''s single open remesa is not on, '
  'and the execution has no successful cambiar_servicio / marcar_destino_usd to it and no agent-declared pending row, raises ONE alert for '
  'the team (notifications type coherencia_servicio). Changes nothing, writes nothing to the customer. Returns {coherente, ...}.';

REVOKE ALL ON FUNCTION public.cerebro_verificar_coherencia_servicio(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_verificar_coherencia_servicio(uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_coherencia_resolver(uuid, uuid, text) FROM PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
