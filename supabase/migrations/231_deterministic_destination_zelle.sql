-- =====================================================================
-- 231 -- The customer's own words also decide Zelle (staging first)
--
-- odd/tasks/bot-change-service.md (Part C). Production 2026-10-08 (Carlos): "Voy a mandar 47100 GYD" / "Puede ser en USD en Bayamo, granma?"
-- (cash USD 290 -> 162) / [receipt] / "Mejor zelle" / "Ahora paso la cuenta" / "Ahora envio cuenta zelle" / "No quiero efectivo en cuba" /
-- "Quiero zelle". The operation was created efectivo_usd by the receipt turn (the LLM called marcar_destino_usd('efectivo') from chat memory
-- AFTER "Mejor zelle" had arrived) and cerebro_registrar_destino returned NULL for every Zelle sentence: it only knew clasica / tropical / cup.
-- The principle of 157 stands: the customer's own words decide, not whether the LLM remembered to call a tool. 231 extends that mechanism
-- (the n8n node "Registrar destino auto" calls cerebro_registrar_destino(conversation, text) on every customer text turn) instead of adding
-- another LLM tool, and uses 230's engine (cerebro_cambiar_servicio) for the change itself.
--
-- 1. cerebro_destino_pendiente: tipo also accepts 'zelle'; new column origen ('cliente' = the customer's words, 'herramienta' = written by the
--    marcar_destino_usd tool through 221). Only 'cliente' rows count in item 6.
-- 2. cerebro_detectar_destino(text) stays IMMUTABLE, pure text, whole words, NULL on ambiguity. It now also returns 'zelle'.
--    RULES (decided here, tested in deterministic-destination-zelle.sql):
--    * Accents and case are folded first (translate(lower())); an e-mail token is removed before looking for 'zelle' ("juan.zelle@x.com" is an
--      address, not a choice).
--    * NEGATION: a rail the customer rejects in the turn is not a named rail. Rejected = "no | ni | sin | nunca | tampoco | jamas | en vez de |
--      en lugar de" followed by up to four words (none of pero / sino / mejor / prefiero / entonces / ahora / y / e, and no comma) and then the
--      rail; or the rail followed by "no" and a space ("zelle no", "zelle no, tropical") unless that "no" is followed by another rail; or the
--      rail, a comma and a bare "no" closing the sentence. "pesos cubanos, no dolares" keeps naming CUP (the "no" refers to dollars). When the
--      negation scope is unclear the answer is NULL, never a rail. A rail that is rejected is dropped and the rest of the turn is judged:
--      "no quiero zelle, mejor tropical" -> tropical; "no zelle" -> NULL; "No quiero efectivo en cuba" -> NULL (efectivo is not detected at all).
--    * TWO DIFFERENT POSITIVE RAILS -> NULL ("zelle o clasica?", "zelle o cup"). 157's own rule is kept for the card rails: clasica and tropical
--      together -> NULL; clasica/tropical beat a stray "cup".
--    * QUESTIONS: 157 never treated questions for clasica / tropical / cup ("cuanto es por clasica?" still names clasica: those results must not
--      change, and re-typing a card that is already a card rail moves no money category). Zelle is different: it changes the amount and the
--      category of the money. A turn that only ASKS about Zelle is not a choice: "?" / "¿", or an interrogative word (cuanto, tienen, hay, se puede,
--      puedo, aceptan, como, cual, ...) -> NULL ("¿tienen zelle?", "cuanto es por zelle?", "se puede por zelle?", "cuanto seria por zelle").
--      A statement of choice names Zelle ("mejor zelle", "quiero zelle", "por zelle", "que sea zelle", "ponlo por zelle", "envialo por zelle",
--      "ahora envio cuenta zelle", "es para zelle", bare "zelle"). The registrar applies the same question test (cerebro_destino_es_pregunta)
--      before it lets a CARD rail replace a Zelle / cash operation (item 3), so "y por clasica cuanto seria?" over a Zelle quote changes nothing.
--    * CASH ("efectivo") IS NOT DETECTED HERE ON PURPOSE. In this business customers also DEPOSIT in cash with an agent, so the word is ambiguous
--      between the deposit channel and the delivery rail. Cash stays on the LLM tool path (marcar_destino_usd('efectivo')) and on
--      cerebro_cambiar_servicio.
--    * Results for inputs that carry neither "zelle" nor a negation word are exactly 157 / 174's (proved by the table in the assertion).
-- 3. cerebro_registrar_destino_v2(conversation, text, execution, only_cards) RETURNS jsonb, and cerebro_registrar_destino(conversation, text) RETURNS
--    text kept as a thin wrapper (same signature, same grants, returns the detected tipo, NULL when none; it now also applies the Zelle change).
--    The n8n node today reads NOTHING from the result (its output is not connected to anything; verified read-only on the production and staging
--    workflows), so the wrapper is risk-free for the node and the Zelle fix works BEFORE the node is switched to v2.
--    v2 result (jsonb, always has tipo, registrado, ok, changed): tipo (detected or null), registrado (the destination was recorded), ok, changed,
--    and either cerebro_cambiar_servicio's own payload (servicio, source_amount_gyd, destination_amount, destination_currency, rate, previous{servicio,
--    destination_amount, destination_currency, rate}, retired_recipients, status, operation_id) or reason: sin_destino | sin_operacion |
--    estado_no_permite (+status) | operacion_ambigua | bloqueado_por_humano (+campo) | por_debajo_del_minimo (+minimo_gyd, source_amount_gyd) |
--    varios_destinatarios | es_pregunta | tipo_no_soportado.
--    Flow: record the destination (pending, 24 h, as 157) and, if the conversation has its single open remesa, apply it:
--    * Zelle, or any rail when the operation's current rail is zelle / efectivo_usd, or when the rail lock was left by the automation (a customer
--      who changes their mind again): through cerebro_cambiar_servicio (230: retires recipients of the old kind, recalculates the quote with the
--      existing rules, locks the rail as automation, one audit row, refuses human locks, statuses, the minimum). The recipients' human lock
--      ('beneficiaries' not stamped automation:) also stops it. No change logic is re-implemented here.
--    * card -> card with no lock: 157's own path, unchanged (only its result is now reported).
--    * two open remesas or none: record and apply nothing, say why (no hand-over from here).
--    The pending row is replaced AFTER the change on the cross-rail path: the engine reads cerebro_riel_op, which falls back to the pending row,
--    and would otherwise see "already zelle".
--    only_cards = true is for cerebro_marcar_destino_usd (221), which keeps exactly its 221 behaviour (no cross-rail change from a tool call).
-- 4. BEFORE INSERT trigger on remittance_beneficiaries (157/169/221): UNCHANGED. It only reads pending 'clasica' / 'tropical', so a pending
--    'zelle' is ignored: a card + phone arriving while zelle is pending stays a card and does not become 'zelle' (a different data shape). The
--    pending row is not cleared by the card (decision: the trigger never guesses; a later statement of the customer replaces it).
-- 5. AFTER INSERT trigger on remittance_operations (new): a remesa created with no rail while the conversation holds a pending zelle (<24 h) and
--    is its single open remesa is made zelle through the same engine ("zelle first, operation created later" - the incident's receipt turn).
--    It never blocks the insert (errors become warnings) and never hands over.
-- 6. cerebro_marcar_destino_usd (221 body + two changes): (a) the stale-write guard: when the customer stated a DIFFERENT rail in the last 5 minutes
--    (pending row, origen 'cliente') it returns the 'ERROR: ...' row naming the rail the customer chose and writes nothing; (b) its internal
--    call goes to v2 with only_cards = true. Signature, grants, return shape and every other behaviour identical.
-- 7. 230's lock: the automation: stamp it leaves on the rail never blocks a second change by the bot (zelle -> cup -> zelle tested).
-- Pre-231 md5 (pg_get_functiondef, staging 2026-10-08; ROLLBACK-231 restores exactly these): cerebro_detectar_destino 31f6d02d599b491c586284251b0502f9,
-- cerebro_registrar_destino c87c36beafde0cd256a601ee7290d045, cerebro_marcar_destino_usd f239d898e9533b82a9822f4eb98ee6e7.
-- Staging had no drift against the repo's latest definitions (174 detector, 157 registrar, 221 marcar + trigger).
-- Guarded by supabase/staging/assertions/deterministic-destination-zelle.sql. ROLLBACK: ROLLBACK-231-deterministic-destination-zelle.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. cerebro_destino_pendiente learns 'zelle' and who wrote the row
-- ---------------------------------------------------------------------
ALTER TABLE public.cerebro_destino_pendiente DROP CONSTRAINT cerebro_destino_pendiente_tipo_check;
ALTER TABLE public.cerebro_destino_pendiente ADD CONSTRAINT cerebro_destino_pendiente_tipo_check
  CHECK (tipo = ANY (ARRAY['clasica'::text, 'tropical'::text, 'cuban_card'::text, 'zelle'::text]));
ALTER TABLE public.cerebro_destino_pendiente ADD COLUMN IF NOT EXISTS origen text NOT NULL DEFAULT 'cliente'
  CHECK (origen IN ('cliente', 'herramienta'));
COMMENT ON COLUMN public.cerebro_destino_pendiente.origen IS
  '231. cliente = stated by the customer''s own words (cerebro_registrar_destino from the n8n node); herramienta = written by '
  'cerebro_marcar_destino_usd (221). Only cliente rows make the tool refuse a different rail.';

-- ---------------------------------------------------------------------
-- 2. detector helpers and the detector
-- ---------------------------------------------------------------------
-- A rail (regex fragment p_rail) is rejected in p_txt (already folded: lower case, no accents).
CREATE OR REPLACE FUNCTION public.cerebro_destino_riel_negado(p_txt text, p_rail text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT
    -- "no quiero zelle", "ya no en CUP", "sin zelle", "en vez de zelle": a negator, up to four words, then the rail
    p_txt ~* ('(^|[^[:alnum:]])(no|ni|sin|nunca|tampoco|jamas|(vez|lugar)[[:space:]]+de)[[:space:]]+'
              || '(?:(?!(pero|sino|mejor|prefiero|entonces|ahora|y|e)([^[:alnum:]]|$))[[:alnum:]]+[[:space:]]+){0,4}'
              || '(' || p_rail || ')([^[:alnum:]]|$)')
    -- "zelle no", "zelle no, tropical" (not when that "no" is followed by another rail: "tropical no zelle")
    OR p_txt ~* ('(^|[^[:alnum:]])(' || p_rail || ')[[:space:]]+no(?![[:alnum:]])'
                 || '(?![[:space:]]+(zelles?|clasicas?|tropical(es)?|cup|pesos)([^[:alnum:]]|$))')
    -- "zelle, no."
    OR p_txt ~* ('(^|[^[:alnum:]])(' || p_rail || ')[[:space:]]*,[[:space:]]*no(?![[:alnum:]])[[:space:]]*([.!?;]|$)');
$function$;

-- The turn only asks (or looks like it asks); folded text expected.
CREATE OR REPLACE FUNCTION public.cerebro_destino_es_pregunta(p_texto text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT coalesce(p_texto, '') ~ '[?¿]'
      OR translate(lower(coalesce(p_texto, '')), 'áéíóúüÁÉÍÓÚÜ', 'aeiouuaeiouu') ~*
         '(^|[^[:alnum:]])(cuanto|cuantos|cuantas|tienen|tiene|tendran|hay|se[[:space:]]+puede|puedo|puedes|pueden|puede|aceptan|manejan|trabajan|como|cual|cuales|existe|sera|seria|serian|que[[:space:]]+tal|por[[:space:]]+que|sabe|saben|quisiera[[:space:]]+saber|quiero[[:space:]]+saber|informacion)([^[:alnum:]]|$)';
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_detectar_destino(p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  c_w        constant text := '(^|[^[:alnum:]])';
  c_e        constant text := '([^[:alnum:]]|$)';
  r_zelle    constant text := 'zelles?';
  r_clasica  constant text := 'clasicas?';
  r_tropical constant text := 'tropical(es)?';
  r_cup      constant text := '(cup|pesos[[:space:]]+cubanos)';
  v_txt      text := translate(lower(coalesce(p_texto, '')), 'áéíóúüÁÉÍÓÚÜ', 'aeiouuaeiouu');
  v_sin_mail text;
  v_zelle    boolean;
  v_clasica  boolean;
  v_tropical boolean;
  v_cup      boolean;
BEGIN
  -- (231) An e-mail token ("juan.zelle@gmail.com") is an address, not a choice.
  v_sin_mail := regexp_replace(v_txt, '[^[:space:]]*@[^[:space:]]*', ' ', 'g');

  -- (231) A rail the customer rejects in the turn is not a named rail.
  v_zelle    := v_sin_mail ~* (c_w || r_zelle || c_e)
                AND NOT cerebro_destino_riel_negado(v_sin_mail, r_zelle);
  -- (174) Plurals too: "a unas tarjetas clasicas", "a las tropicales".
  v_clasica  := v_txt ~* (c_w || r_clasica || c_e)
                AND NOT cerebro_destino_riel_negado(v_txt, r_clasica);
  v_tropical := v_txt ~* (c_w || r_tropical || c_e)
                AND NOT cerebro_destino_riel_negado(v_txt, r_tropical);
  v_cup      := (v_txt ~* (c_w || 'cup' || c_e) OR v_txt ~* (c_w || 'pesos[[:space:]]+cubanos' || c_e))
                AND NOT cerebro_destino_riel_negado(v_txt, r_cup);

  IF v_zelle THEN
    -- Zelle changes the amount and the category of the money: two rails, or a turn that only asks, name nothing.
    IF v_clasica OR v_tropical OR v_cup THEN
      RETURN NULL;
    END IF;
    IF cerebro_destino_es_pregunta(v_txt) THEN
      RETURN NULL;
    END IF;
    RETURN 'zelle';
  END IF;

  IF v_clasica AND NOT v_tropical THEN
    RETURN 'clasica';
  ELSIF v_tropical AND NOT v_clasica THEN
    RETURN 'tropical';
  ELSIF v_cup AND NOT v_clasica AND NOT v_tropical THEN
    RETURN 'cuban_card';
  END IF;

  -- Both rails named, or nothing this function recognises.
  RETURN NULL;
END $function$;

COMMENT ON FUNCTION public.cerebro_detectar_destino(text) IS
  '157/174/231. zelle / clasica / tropical / cuban_card out of one turn of the customer''s text, or NULL when the turn names two rails, '
  'rejects the rail it names, or only asks about Zelle. IMMUTABLE: whole-word regexes, no table access. Cash is deliberately not detected.';

-- ---------------------------------------------------------------------
-- 3. cerebro_registrar_destino_v2 and the v1 wrapper
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_registrar_destino_v2(p_conv uuid, p_texto text, p_execution_id text DEFAULT NULL, p_solo_tarjetas boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tipo   text;
  v_n      integer := 0;
  v_op     uuid;
  v_lock   jsonb;
  v_dm     text;
  v_status text;
  v_cur    text;
  v_cross  boolean;
  v_res    jsonb;
  v_origen text := CASE WHEN p_solo_tarjetas THEN 'herramienta' ELSE 'cliente' END;
  v_o      remittance_operations%ROWTYPE;
  v_prev   jsonb;
  v_lstat  text;
BEGIN
  v_tipo := cerebro_detectar_destino(p_texto);
  IF v_tipo IS NULL THEN
    RETURN jsonb_build_object('tipo', NULL, 'registrado', false, 'ok', false, 'changed', false, 'reason', 'sin_destino');
  END IF;

  SELECT count(*) OVER (), o.id, o.admin_locked_fields, o.delivery_method, o.status
    INTO v_n, v_op, v_lock, v_dm, v_status
    FROM public.remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.service_type = 'remesa'
     AND o.status NOT IN ('completed', 'cancelled')
   LIMIT 1;
  v_n := coalesce(v_n, 0);
  v_lock := coalesce(v_lock, '{}'::jsonb);

  v_cross := false;
  IF v_n = 1 THEN
    v_cur := coalesce(nullif(v_dm, ''),
                      (SELECT b.beneficiary_type FROM public.remittance_beneficiaries b
                        WHERE b.operation_id = v_op AND b.status = 'vigente' ORDER BY b.position LIMIT 1));
    v_cross := NOT p_solo_tarjetas
               AND (v_tipo = 'zelle'
                    OR coalesce(v_cur IN ('zelle', 'efectivo_usd'), false)
                    OR (v_lock ? 'delivery_method' AND coalesce(v_lock #>> '{delivery_method,by}', '') LIKE 'automation:%'));
  END IF;

  -- A card rail may not replace a Zelle / cash operation on a mere question ("y por clasica cuanto seria?"): nothing recorded either.
  IF v_cross AND v_tipo <> 'zelle' AND cerebro_destino_es_pregunta(p_texto) THEN
    RETURN jsonb_build_object('tipo', v_tipo, 'registrado', false, 'ok', false, 'changed', false, 'reason', 'es_pregunta');
  END IF;

  -- Last statement wins. A customer who corrects the rail corrects it. (Before the change on 157's path; after it on the cross-rail path,
  -- see the header.)
  IF NOT v_cross THEN
    INSERT INTO public.cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen)
    VALUES (p_conv, v_tipo, now(), v_origen)
    ON CONFLICT (conversation_id) DO UPDATE
       SET tipo = EXCLUDED.tipo,
           actualizado = EXCLUDED.actualizado,
           origen = CASE WHEN cerebro_destino_pendiente.tipo = EXCLUDED.tipo AND cerebro_destino_pendiente.origen = 'cliente'
                         THEN 'cliente' ELSE EXCLUDED.origen END;
  END IF;

  IF v_n = 0 THEN
    SELECT o.status INTO v_lstat FROM public.remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'remesa' ORDER BY o.created_at DESC LIMIT 1;
    v_res := CASE WHEN v_lstat IS NULL THEN jsonb_build_object('ok', false, 'reason', 'sin_operacion')
                  ELSE jsonb_build_object('ok', false, 'reason', 'estado_no_permite', 'status', v_lstat) END;
  ELSIF v_n > 1 THEN
    v_res := jsonb_build_object('ok', false, 'reason', 'operacion_ambigua');
  ELSIF v_cross THEN
    IF v_lock ? 'beneficiaries' AND coalesce(v_lock #>> '{beneficiaries,by}', '') NOT LIKE 'automation:%' THEN
      v_res := jsonb_build_object('ok', false, 'reason', 'bloqueado_por_humano', 'campo', 'beneficiaries', 'operation_id', v_op);
    ELSE
      -- The engine reads cerebro_riel_op, which falls back to the pending row: take the row away while it decides, put it back after.
      DELETE FROM public.cerebro_destino_pendiente WHERE conversation_id = p_conv;
      v_res := cerebro_cambiar_servicio(p_conv, v_tipo, p_execution_id);
    END IF;
    INSERT INTO public.cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen)
    VALUES (p_conv, v_tipo, now(), v_origen)
    ON CONFLICT (conversation_id) DO UPDATE SET tipo = EXCLUDED.tipo, actualizado = EXCLUDED.actualizado, origen = EXCLUDED.origen;
  ELSIF p_solo_tarjetas AND v_tipo = 'zelle' THEN
    v_res := jsonb_build_object('ok', false, 'reason', 'tipo_no_soportado');
  ELSIF NOT (v_lock ? 'beneficiaries') AND NOT (v_lock ? 'delivery_method') THEN
    SELECT * INTO v_o FROM public.remittance_operations WHERE id = v_op;
    v_prev := jsonb_build_object('servicio', v_cur, 'destination_amount', v_o.quoted_destination_amount,
                                 'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate);

    -- Card-rail rows only. zelle, multiple_distribution and efectivo_usd are different kinds of delivery and are never re-typed by this.
    UPDATE public.remittance_beneficiaries
       SET beneficiary_type = v_tipo
     WHERE operation_id = v_op
       AND status = 'vigente'
       AND beneficiary_type IN ('cuban_card', 'clasica', 'tropical');

    UPDATE public.remittance_operations
       SET delivery_method = v_tipo
     WHERE id = v_op
       AND (delivery_method IS NULL
            OR delivery_method IN ('cuban_card', 'clasica', 'tropical'));

    -- 157: wrapped, a calculator failure must not throw away the destination the customer asked for.
    BEGIN
      PERFORM crm_calcular_monto_destino(v_op);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[wacrm] crm_calcular_monto_destino failed after destino % on operation % (%): %',
        v_tipo, v_op, SQLSTATE, SQLERRM;
    END;

    SELECT * INTO v_o FROM public.remittance_operations WHERE id = v_op;
    v_res := jsonb_build_object(
      'ok', (v_o.delivery_method IS NOT DISTINCT FROM v_tipo),
      'changed', (v_o.delivery_method IS DISTINCT FROM v_dm
                  OR v_o.quoted_destination_amount IS DISTINCT FROM (v_prev ->> 'destination_amount')::numeric
                  OR v_o.destination_currency IS DISTINCT FROM (v_prev ->> 'destination_currency')),
      'operation_id', v_op, 'servicio', v_tipo, 'source_amount_gyd', v_o.quoted_source_amount,
      'destination_amount', v_o.quoted_destination_amount, 'destination_currency', v_o.destination_currency,
      'rate', v_o.quoted_destination_rate, 'previous', v_prev, 'status', v_o.status);
  ELSE
    v_res := jsonb_build_object('ok', false, 'reason', 'bloqueado_por_humano', 'operation_id', v_op,
                                'campo', CASE WHEN v_lock ? 'delivery_method' THEN 'delivery_method' ELSE 'beneficiaries' END);
  END IF;

  RETURN jsonb_build_object('tipo', v_tipo, 'registrado', true, 'changed', false) || coalesce(v_res, '{}'::jsonb);
END $function$;

COMMENT ON FUNCTION public.cerebro_registrar_destino_v2(uuid, text, text, boolean) IS
  '231. Records the destination the customer stated (zelle / clasica / tropical / cuban_card) and applies it to the conversation''s single open '
  'remesa; returns jsonb {tipo, registrado, ok, changed, ...} with the new amount and the previous one. p_solo_tarjetas = 157''s behaviour only '
  '(used by the marcar_destino_usd tool).';

REVOKE ALL ON FUNCTION public.cerebro_registrar_destino_v2(uuid, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_destino_v2(uuid, text, text, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.cerebro_registrar_destino(p_conv uuid, p_texto text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN cerebro_registrar_destino_v2(p_conv, p_texto, NULL, false) ->> 'tipo';
END $function$;

COMMENT ON FUNCTION public.cerebro_registrar_destino(uuid, text) IS
  '157/231. Thin wrapper of cerebro_registrar_destino_v2: returns the detected tipo (zelle / clasica / tropical / cuban_card), or NULL when the '
  'text named nothing usable. Also applies the change to the single open remesa.';

REVOKE EXECUTE ON FUNCTION public.cerebro_registrar_destino(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_destino(uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.cerebro_destino_riel_negado(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_destino_es_pregunta(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_detectar_destino(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_destino_riel_negado(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_destino_es_pregunta(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_detectar_destino(text) TO service_role;

-- ---------------------------------------------------------------------
-- 5. A remesa created while zelle is pending is zelle
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_destino_pendiente_op_creada()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_origen text;
BEGIN
  IF NEW.conversation_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT p.origen INTO v_origen
    FROM public.cerebro_destino_pendiente p
   WHERE p.conversation_id = NEW.conversation_id AND p.tipo = 'zelle' AND p.actualizado > now() - interval '24 hours';
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  -- Only when this is the conversation's single open remesa (never a hand-over from a trigger).
  IF (SELECT count(*) FROM public.remittance_operations o
       WHERE o.conversation_id = NEW.conversation_id AND o.service_type = 'remesa' AND o.status NOT IN ('completed', 'cancelled')) <> 1 THEN
    RETURN NULL;
  END IF;
  BEGIN
    DELETE FROM public.cerebro_destino_pendiente WHERE conversation_id = NEW.conversation_id;
    PERFORM cerebro_cambiar_servicio(NEW.conversation_id, 'zelle', 'pendiente-zelle');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] pending zelle not applied to new operation % (%): %', NEW.id, SQLSTATE, SQLERRM;
  END;
  INSERT INTO public.cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen)
  VALUES (NEW.conversation_id, 'zelle', now(), v_origen)
  ON CONFLICT (conversation_id) DO UPDATE SET tipo = EXCLUDED.tipo, actualizado = EXCLUDED.actualizado, origen = EXCLUDED.origen;
  RETURN NULL;
END $function$;

DROP TRIGGER IF EXISTS trg_zz_destino_zelle_al_crear ON public.remittance_operations;
CREATE TRIGGER trg_zz_destino_zelle_al_crear
  AFTER INSERT ON public.remittance_operations
  FOR EACH ROW
  WHEN (NEW.service_type = 'remesa' AND NEW.delivery_method IS NULL AND NEW.status NOT IN ('completed', 'cancelled'))
  EXECUTE FUNCTION public.cerebro_destino_pendiente_op_creada();

REVOKE ALL ON FUNCTION public.cerebro_destino_pendiente_op_creada() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. cerebro_marcar_destino_usd -- 221's body + the stale-write guard + cards-only call
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
    RETURN QUERY SELECT NULL::uuid AS id,
      'ERROR: el tipo debe ser clasica, tropical o efectivo. No se marco nada.'::text AS accion;
  END IF;

  -- (231) Stale-write guard. The customer's own words (cerebro_registrar_destino, every customer text turn) are newer than a model that
  -- marks a rail from chat memory: when the customer stated a DIFFERENT rail in the last 5 minutes, write nothing and tell the agent.
  IF v_t IS NOT NULL THEN
    SELECT p.tipo INTO v_pend
      FROM cerebro_destino_pendiente p
     WHERE p.conversation_id = p_conversation_id
       AND p.origen = 'cliente'
       AND p.actualizado > now() - interval '5 minutes';
    IF v_pend IS NOT NULL AND v_pend IS DISTINCT FROM v_marker THEN
      RETURN QUERY SELECT NULL::uuid AS id,
        ('ERROR: el cliente acaba de elegir ' ||
         CASE v_pend WHEN 'zelle' THEN 'Zelle' WHEN 'cuban_card' THEN 'CUP (tarjeta en pesos)' WHEN 'clasica' THEN 'Clasica' ELSE 'Tropical' END ||
         ' con sus propias palabras y tu intentas marcar ' || v_t ||
         '. No se marco nada. La via vigente es la que el cliente dijo; si el cliente quiere otra, que lo diga y se cambia solo.')::text AS accion;
      RETURN;
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
        -- (221/231) the rail is also the pending destination: re-types a card already registered (157's rules, cards only).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino_v2(p_conversation_id, lower(v_t), p_execution_id, true);
        END IF;
        RETURN QUERY SELECT v_op AS id,
          'sin cambios: ese destino ya estaba marcado'::text AS accion;
      ELSE
        UPDATE remittance_operations o
           SET delivery_method = coalesce(v_marker, v_ben, o.delivery_method)
         WHERE o.id = v_op
           AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, v_ben, o.delivery_method);
        -- (221/231) the rail is also the pending destination: re-types a card already registered (157's rules, cards only).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino_v2(p_conversation_id, lower(v_t), p_execution_id, true);
        END IF;
        RETURN QUERY SELECT v_op AS id,
          ('destino marcado: entrega en USD por ' || v_t)::text AS accion;
      END IF;
    END IF;
    RETURN;
  END IF;

  -- no operation: ambiguo, or the node's `ins`
  IF v_resultado = 'ambigua' THEN
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
    UPDATE remittance_operations o
       SET delivery_method = coalesce(v_marker, o.delivery_method)
     WHERE o.id = v_nuevo
       AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, o.delivery_method);
    -- (221/231) the rail is also the pending destination: re-types a card already registered (157's rules, cards only).
    IF v_t IN ('Clasica', 'Tropical') THEN
      PERFORM cerebro_registrar_destino_v2(p_conversation_id, lower(v_t), p_execution_id, true);
    END IF;
    RETURN QUERY SELECT v_nuevo AS id,
      ('envio nuevo creado, entrega en USD por ' || v_t)::text AS accion;
  END IF;
END;
$function$;

NOTIFY pgrst, 'reload schema';
