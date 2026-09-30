-- =====================================================================
-- 157 -- A deterministic USD destination: the customer's own words decide,
--         not whether the LLM remembered to call marcar_destino_usd
--
-- PROBLEM
--   "ENTREGA EN USD: <tipo>" is written by exactly one writer: the
--   marcar_destino_usd tool in the n8n bot. The rule that says to call it
--   lives in prose, in the `Agente Remesas` systemMessage ("SI ES CLASICA O
--   TROPICAL ... Y ADEMAS llama marcar_destino_usd ... Sin esa llamada, en
--   el tablero se ve igual que un envio en CUP"). The deterministic gate
--   that fires instead, "Beneficiario completo?", only checks
--   tarjeta_final + celular_final, so a customer who says "es para Clasica"
--   and then sends card + phone gets a cuban_card beneficiary, a
--   cuban_card delivery_method, and a CUP quote. 40,000 GYD at 3 CUP/GYD
--   quotes as 120,000 CUP for a remesa that has to be paid in dollars.
--
--   The note-only mark also cannot be replayed: once the turn is gone, the
--   destination is gone with it.
--
-- WHAT
--   1. cerebro_destino_pendiente -- one row per conversation holding the
--      destination the customer actually stated, for as long as the remesa
--      in progress may still need it. Internal table, RLS on with no
--      policy (the 037/096/156 lock-down): service_role only.
--   2. cerebro_detectar_destino(p_texto) -- IMMUTABLE, pure text. Clasica,
--      Tropical or CUP out of ONE turn of the customer's words. Both rails
--      named, or neither -> NULL: the function refuses to guess, because a
--      wrong rail here is money delivered the wrong way.
--   3. cerebro_registrar_destino(p_conv, p_texto) -- records that
--      destination and applies it to the conversation's single open remesa
--      (its card-rail beneficiaries, its delivery_method, and a recalculated
--      amount), honouring the 096/098 admin locks. Two open remesas or
--      none: it records the destination and applies nothing.
--   4. A BEFORE INSERT trigger on remittance_beneficiaries, so the "via
--      first, card later" order works on EVERY registration path (n8n notes
--      parse, 123's add RPC, 127/129 reparto, a future one) without any of
--      them knowing this exists.
--   5. crm_calcular_monto_destino: 111's body verbatim with 'clasica' and
--      'tropical' added to the dollar branch, exactly where 'zelle' is.
--      Same rate, same floor, same eligibility, same locks.
--   6. 155's close trigger also clears the pending row, on 155's own rule.
--
-- WHY ONE TABLE AND NOT A COLUMN ON THE REMESA
--   The destination routinely arrives BEFORE the remesa exists ("lo mando
--   por Tropical" at the start of the chat, card and phone five turns
--   later). A column on remittance_operations would have nowhere to live
--   yet. One row per conversation, keyed by the conversation, is the only
--   shape that holds the answer from turn 1 to the beneficiary INSERT.
--
-- WHY THE 24 h WINDOW
--   The same constant 156's recarga guard already uses: a destination
--   stated days ago in a chat that has since gone quiet must not re-type a
--   card that arrives today for a different remittance.
--
-- WHY NULL ON AMBIGUITY
--   "clasica o tropical" is a question, not an instruction. Falling back to
--   cuban_card would be the same bug this migration exists to remove, and
--   falling back to either rail would be a coin flip. The pending row keeps
--   whatever a later turn states.
--
-- ROLLBACK: ROLLBACK-157-deterministic-usd-destination.sql
-- Guarded by supabase/staging/assertions/deterministic-usd-destination.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. cerebro_destino_pendiente
-- ---------------------------------------------------------------------
-- Internal bookkeeping, never read by the panel: the source of truth for
-- the destination stays the beneficiary/delivery_method pair that every
-- read path already uses. This table only carries the answer between the
-- turn that states it and the INSERT that needs it.

CREATE TABLE IF NOT EXISTS public.cerebro_destino_pendiente (
  conversation_id uuid PRIMARY KEY REFERENCES public.conversations(id) ON DELETE CASCADE,
  tipo            text NOT NULL CHECK (tipo IN ('clasica', 'tropical', 'cuban_card')),
  actualizado     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.cerebro_destino_pendiente IS
  '157. The delivery rail the customer stated in their own words, kept per '
  'conversation until the remesa closes. Written by '
  'cerebro_registrar_destino, read by the BEFORE INSERT trigger on '
  'remittance_beneficiaries. Replaced on every new statement: the last '
  'thing the customer said about the destination is the destination.';

-- Same lock-down 156 gives the other internal table: RLS on with no policy
-- means no row is reachable by anon or authenticated whatever grants they
-- hold, and service_role bypasses RLS. The SECURITY DEFINER functions
-- below still read it, because they run as the table owner.
REVOKE ALL ON public.cerebro_destino_pendiente FROM PUBLIC, anon, authenticated;
ALTER TABLE public.cerebro_destino_pendiente ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- 2. cerebro_detectar_destino -- what did the customer just say?
-- ---------------------------------------------------------------------
-- IMMUTABLE and table-free on purpose: this is the one function an n8n
-- node can be pointed at safely, and it is trivially unit-testable.
--
-- WHOLE WORDS, ON PURPOSE. 'clasicamente' is not a delivery rail, and
-- 'cupones' is not a currency. The bracket spells all FOUR letters of
-- "clásica" -- a, á, A, Á -- because Postgres folds case for ASCII only:
-- under a C or en_US.UTF-8 collation '~*' alone matches neither 'CLÁSICA'
-- nor 'clásica' with a pattern written as 'clasica'.

CREATE OR REPLACE FUNCTION public.cerebro_detectar_destino(p_texto text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_txt      text := coalesce(p_texto, '');
  v_clasica  boolean;
  v_tropical boolean;
  v_cup      boolean;
BEGIN
  v_clasica  := v_txt ~* '(^|[^[:alnum:]])cl[aáAÁ]sica([^[:alnum:]]|$)';
  v_tropical := v_txt ~* '(^|[^[:alnum:]])tropical([^[:alnum:]]|$)';
  v_cup      := v_txt ~* '(^|[^[:alnum:]])cup([^[:alnum:]]|$)'
             OR v_txt ~* '(^|[^[:alnum:]])pesos[[:space:]]+cubanos([^[:alnum:]]|$)';

  IF v_clasica AND NOT v_tropical THEN
    RETURN 'clasica';
  ELSIF v_tropical AND NOT v_clasica THEN
    RETURN 'tropical';
  ELSIF v_cup AND NOT v_clasica AND NOT v_tropical THEN
    RETURN 'cuban_card';
  END IF;

  -- Both rails named, or nothing this function recognises.
  RETURN NULL;
END $$;

COMMENT ON FUNCTION public.cerebro_detectar_destino(text) IS
  '157. clasica / tropical / cuban_card out of one turn of the customer''s '
  'text, or NULL when the turn names both dollar rails or neither. '
  'IMMUTABLE: whole-word regexes, no table access.';

REVOKE ALL ON FUNCTION public.cerebro_detectar_destino(text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. cerebro_registrar_destino -- record it, then apply it
-- ---------------------------------------------------------------------
-- Two jobs, in this order, because they answer different failures:
--   - the pending row covers "the via was stated before the card";
--   - the UPDATE covers "the card was registered before the via".
-- Either alone leaves half the orders broken.
--
-- The pending row is written even when there is nothing to apply to. That
-- is the whole point of writing it first: the turn that states the
-- destination is usually not the turn that creates the remesa.
--
-- EXACTLY ONE open remesa. With two open remesas on the same conversation
-- "the" operation is not a well-defined row to re-type, and picking the
-- newest would be a coin flip on a money field. The destination stays
-- recorded and the next statement of it applies cleanly.
--
-- count(*) OVER () is the whole filtered set while the selected row is one
-- of it, so the "is it really only one?" question is answered in the same
-- snapshot as "which one?".

CREATE OR REPLACE FUNCTION public.cerebro_registrar_destino(p_conv uuid, p_texto text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tipo  text;
  v_n     integer := 0;
  v_op_id uuid;
  v_lock  jsonb;
BEGIN
  v_tipo := cerebro_detectar_destino(p_texto);
  IF v_tipo IS NULL THEN
    RETURN NULL;
  END IF;

  -- Last statement wins. A customer who corrects the rail corrects it.
  INSERT INTO public.cerebro_destino_pendiente (conversation_id, tipo, actualizado)
  VALUES (p_conv, v_tipo, now())
  ON CONFLICT (conversation_id) DO UPDATE
     SET tipo = EXCLUDED.tipo,
         actualizado = EXCLUDED.actualizado;

  SELECT count(*) OVER (), o.id, o.admin_locked_fields
    INTO v_n, v_op_id, v_lock
    FROM public.remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.service_type = 'remesa'
     AND o.status NOT IN ('completed', 'cancelled')
   LIMIT 1;

  IF v_n = 1 THEN
    v_lock := coalesce(v_lock, '{}'::jsonb);

    -- 'beneficiaries' is 098's lock (a human added or corrected a
    -- beneficiary), 'delivery_method' is 096's (a human set the rail).
    -- Either one means a person already decided this on purpose.
    IF NOT (v_lock ? 'beneficiaries') AND NOT (v_lock ? 'delivery_method') THEN
      -- Card-rail rows only. zelle, multiple_distribution and efectivo_usd
      -- are different kinds of delivery and are never re-typed by this.
      UPDATE public.remittance_beneficiaries
         SET beneficiary_type = v_tipo
       WHERE operation_id = v_op_id
         AND status = 'vigente'
         AND beneficiary_type IN ('cuban_card', 'clasica', 'tropical');

      UPDATE public.remittance_operations
         SET delivery_method = v_tipo
       WHERE id = v_op_id
         AND (delivery_method IS NULL
              OR delivery_method IN ('cuban_card', 'clasica', 'tropical'));

      -- The same call 100's recalc triggers make and 111's one-time
      -- recompute makes. Wrapped like 100's: a calculator failure must not
      -- throw away the destination the customer actually asked for. The
      -- re-type above has already re-fired the calculator through
      -- trg_zz_recalc_destino_beneficiaries; this call is what covers the
      -- case where the row was already the right type.
      BEGIN
        PERFORM crm_calcular_monto_destino(v_op_id);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[wacrm] crm_calcular_monto_destino failed after destino % on operation % (%): %',
          v_tipo, v_op_id, SQLSTATE, SQLERRM;
      END;
    END IF;
  END IF;

  RETURN v_tipo;
END $$;

COMMENT ON FUNCTION public.cerebro_registrar_destino(uuid, text) IS
  '157. Records the destination the customer stated and applies it to the '
  'conversation''s single open remesa (card-rail beneficiaries, '
  'delivery_method, recalculated amount) unless a human locked either. '
  'Returns the detected tipo, or NULL when the text named nothing usable.';

REVOKE EXECUTE ON FUNCTION public.cerebro_registrar_destino(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_destino(uuid, text) TO service_role;

-- ---------------------------------------------------------------------
-- 4. BEFORE INSERT on remittance_beneficiaries
-- ---------------------------------------------------------------------
-- The "via first, card later" order, covered on every registration path
-- there is or will be: the notes parser (042), 123's add RPC, 127/129's
-- reparto writers and anything added tomorrow all land here without
-- knowing this function exists. That is the only reason a card can no
-- longer arrive typed 'cuban_card' on a conversation that already said
-- Clásica.
--
-- TRIGGER ORDER DOES NOT MATTER for correctness: PostgreSQL always runs
-- every BEFORE trigger of a statement before any AFTER trigger, so this
-- rewrite lands before 100's trg_zz_recalc_destino_beneficiaries reads
-- the row, whatever the names say. The name still sorts first on purpose:
-- if a second BEFORE trigger is ever added to this table, alphabetical
-- order then makes the reading order of the two obvious.
--
-- BEFORE INSERT only. An UPDATE that re-types a beneficiary is a
-- deliberate act (123/098) and cerebro_registrar_destino owns it.

CREATE OR REPLACE FUNCTION public.cerebro_destino_pendiente_antes_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tipo text;
BEGIN
  IF NEW.beneficiary_type = 'cuban_card' AND NEW.operation_id IS NOT NULL THEN
    SELECT p.tipo INTO v_tipo
      FROM public.cerebro_destino_pendiente p
      JOIN public.remittance_operations o ON o.conversation_id = p.conversation_id
     WHERE o.id = NEW.operation_id
       AND p.tipo IN ('clasica', 'tropical')
       AND p.actualizado > now() - interval '24 hours'
     LIMIT 1;

    IF v_tipo IS NOT NULL THEN
      NEW.beneficiary_type := v_tipo;
    END IF;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_aa_destino_pendiente_antes_insert ON remittance_beneficiaries;
CREATE TRIGGER trg_aa_destino_pendiente_antes_insert
  BEFORE INSERT ON remittance_beneficiaries
  FOR EACH ROW EXECUTE FUNCTION public.cerebro_destino_pendiente_antes_insert();

REVOKE EXECUTE ON FUNCTION public.cerebro_destino_pendiente_antes_insert() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. crm_calcular_monto_destino -- the dollar branch learns the two rails
-- ---------------------------------------------------------------------
-- 111's body VERBATIM, with ONE line changed: the zelle test becomes a
-- three-value IN list. Same crm_tasa_vigente('usd'), same floor, same
-- eligibility gate, same admin locks, same stale-calculation clearing,
-- same recursion guard, same REVOKE. Nothing else in this function moves,
-- and no one-time recompute block is added: every operation that could
-- change rail is either open (and recalculated by its own trigger) or
-- closed (and its amount is what was actually delivered).
--
-- The beneficiary_type is what this branches on, and it is what
-- cerebro_registrar_destino and the BEFORE INSERT trigger above now set,
-- so a Clásica remesa reaches the same code a Zelle one always did.

CREATE OR REPLACE FUNCTION crm_calcular_monto_destino(p_operation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op            remittance_operations%ROWTYPE;
  v_found         boolean := true;
  v_vigente_count integer;
  v_ben           remittance_beneficiaries%ROWTYPE;
  v_rate          numeric;
  v_amount        numeric;
  v_currency      text;
  v_computable    boolean := false;
BEGIN
  -- Recursion guard: the UPDATEs below re-fire this migration's own AFTER
  -- triggers. If a calculation is already running higher up the call stack,
  -- do nothing here — the flag belongs to that outer invocation, so this
  -- nested call must not touch (and must not reset) it.
  IF current_setting('wacrm.calc_destino', true) = 'on' THEN
    RETURN;
  END IF;

  PERFORM set_config('wacrm.calc_destino', 'on', true);

  BEGIN
    SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
    IF NOT FOUND THEN
      v_found := false;
    END IF;

    -- Eligible at all: exists, is a remesa, is still open, its destination
    -- amount isn't human-locked, and it either has no destination amount
    -- yet or the one it has is this function's own prior calculation (never
    -- a pre-existing/manual value).
    IF v_found
       AND v_op.service_type = 'remesa'
       AND v_op.status NOT IN ('completed', 'cancelled')
       AND NOT (v_op.admin_locked_fields ? 'quoted_destination_amount')
       AND (v_op.quoted_destination_amount IS NULL
            OR coalesce(v_op.quoted_destination_origin, '') = 'calculated')
    THEN
      SELECT count(*) INTO v_vigente_count
        FROM remittance_beneficiaries
       WHERE operation_id = p_operation_id AND status = 'vigente';

      IF v_vigente_count = 1
         AND coalesce(v_op.quoted_source_amount, 0) > 0
         AND upper(coalesce(v_op.source_currency, 'GYD')) = 'GYD'
      THEN
        SELECT * INTO v_ben
          FROM remittance_beneficiaries
         WHERE operation_id = p_operation_id AND status = 'vigente';

        IF v_ben.beneficiary_type IN ('zelle', 'clasica', 'tropical') THEN
          v_rate := crm_tasa_vigente('usd');
          IF v_rate > 0 THEN
            -- Whole units, rounded DOWN, in the business's favour: a
            -- part-unit is never delivered as a full one, because that
            -- hands over more value than the deposit covers (75,000 GYD
            -- at 260 is 288.46 USD; delivering 289 gives away 140 GYD).
            -- Mirrors document-rates.ts deriveAmountFromDeposit and 111's
            -- calculator_amount_from_basis, so the panel and the ledger
            -- cannot disagree about one remesa. n8n's bot has always
            -- floored — this brings the panel in line with it.
            v_amount := floor(v_op.quoted_source_amount / v_rate);
            v_currency := 'USD';
            v_computable := true;
          END IF;
        ELSIF v_ben.beneficiary_type = 'cuban_card' THEN
          v_rate := crm_tasa_vigente('gyd');
          IF v_rate > 0 THEN
            v_amount := round(v_op.quoted_source_amount * v_rate);
            v_currency := 'CUP';
            v_computable := true;
          END IF;
        END IF;
      END IF;

      IF v_computable THEN
        UPDATE remittance_operations
           SET quoted_destination_amount = v_amount,
               destination_currency = v_currency,
               quoted_destination_rate = v_rate,
               quoted_destination_origin = 'calculated'
         WHERE id = p_operation_id
           AND (quoted_destination_amount IS DISTINCT FROM v_amount
                OR destination_currency IS DISTINCT FROM v_currency
                OR quoted_destination_rate IS DISTINCT FROM v_rate
                OR quoted_destination_origin IS DISTINCT FROM 'calculated');

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries')
           AND (v_ben.amount IS NULL OR v_ben.amount_origin = 'calculated')
        THEN
          UPDATE remittance_beneficiaries
             SET amount = v_amount,
                 currency = v_currency,
                 amount_origin = 'calculated'
           WHERE id = v_ben.id
             AND (amount IS DISTINCT FROM v_amount
                  OR currency IS DISTINCT FROM v_currency
                  OR amount_origin IS DISTINCT FROM 'calculated');
        END IF;
      ELSIF v_op.quoted_destination_origin = 'calculated' THEN
        -- No longer computable (e.g. a second beneficiary showed up, or the
        -- rate disappeared) but the current value was this function's own
        -- stale calculation — clear it rather than leave a number nothing
        -- can now reproduce. destination_currency is left untouched: it is
        -- not exclusively this migration's field to clear.
        UPDATE remittance_operations
           SET quoted_destination_amount = NULL,
               quoted_destination_rate = NULL,
               quoted_destination_origin = NULL
         WHERE id = p_operation_id;

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries') THEN
          UPDATE remittance_beneficiaries
             SET amount = NULL,
                 currency = NULL,
                 amount_origin = NULL
           WHERE operation_id = p_operation_id
             AND status = 'vigente'
             AND amount_origin = 'calculated';
        END IF;
      END IF;
    END IF;

    PERFORM set_config('wacrm.calc_destino', 'off', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('wacrm.calc_destino', 'off', true);
    RAISE;
  END;
END $$;

REVOKE ALL ON FUNCTION crm_calcular_monto_destino(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. cerebro_reset_beneficiario_parcial_al_cerrar -- 155's body, +1 line
-- ---------------------------------------------------------------------
-- The pending destination belongs to the remesa in progress for the same
-- reason the partial beneficiary does (155's whole argument): a remesa
-- closed by hand must not leave a stale 'clasica' lying around to re-type
-- the next one's card. Same trigger, same WHEN clause, no new trigger.

CREATE OR REPLACE FUNCTION cerebro_reset_beneficiario_parcial_al_cerrar()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.conversation_id IS NOT NULL THEN
    DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = NEW.conversation_id;
    -- (157) the pending USD destination belongs to the remesa in progress too.
    DELETE FROM cerebro_destino_pendiente WHERE conversation_id = NEW.conversation_id;
  END IF;
  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION cerebro_reset_beneficiario_parcial_al_cerrar() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------
-- The detector and the trigger function stay unreachable from the API;
-- only the entry point n8n calls is granted, and only to service_role --
-- the same 156 posture, and the reason the n8n Postgres credential has to
-- be service_role (remittance_operation_receipts already required it).

NOTIFY pgrst, 'reload schema';
