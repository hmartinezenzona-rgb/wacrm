-- =====================================================================
-- 156 — Structured deposit receipts: the "receipt -> operation" link,
--        out of deals.notes
--
-- PROBLEM (odd/tasks/eliminate-deals.md, Phase 1)
--   The remittance flow is being taken off `deals`, but the link between a
--   deposit receipt and the operation it paid is only free text: one block
--   per receipt appended to deals.notes, separated by E'\n---\n':
--
--     DEPOSITO: 40,000 GYD - APROBADA
--     Destinatario: <text>
--     Via: <text>;
--     Ref: <digits or N/A>[ (<date>)]
--     Destino correcto: SI|NO
--     COMP-<20 hex chars>
--
--   A multi-receipt note repeats block+COMP separated by ---, then a
--   'TOTAL DEPOSITADO: ...' line. Nothing can query "the receipts of this
--   operation" without a regex over the notes, and the moment the notes
--   stop being written (the whole point of eliminating `deals`) that
--   history becomes unreadable.
--
-- WHAT
--   1. public.remittance_operation_receipts — one row per receipt block,
--      already parsed. Indexed by operation, by comp_id and by
--      conversation. RLS on with no policy: the 037/096 lock-down, so the
--      table is only reachable by service_role like the other internal
--      cerebro tables.
--   2. cerebro_parsear_comprobantes(p_notes) — IMMUTABLE, pure regex
--      parsing, one row per block that contains 'DEPOSITO:'. It splits the
--      notes EXACTLY the way the deposit-review panel does (099,
--      crm_comprobantes_de_operacion): same separator, same COMP pattern,
--      same amount/currency pattern. One parser, two callers.
--   3. cerebro_registrar_deposito dual-writes: in each of its three write
--      branches (movido / sumado / creado) it now also inserts the
--      receipts parsed from the note it just received, linked to the
--      operation of the deal the receipt landed on, source 'bot'. The
--      125 body is otherwise untouched — the deal write, the idempotency
--      guard and the operation write are byte-for-byte what they were.
--   4. Backfill: every remesas deal that has a remittance_operations row
--      gets its receipts parsed out of its notes, source 'backfill'.
--
-- WHY source IS NOT NULL
--   'bot' is what cerebro_registrar_deposito wrote; 'backfill' is what this
--   migration derived from history. The transition needs to be able to tell
--   them apart (a re-run of the backfill must never overwrite what the bot
--   recorded), so the column is part of the contract, not metadata.
--
-- WHY comp_id IS NULLABLE
--   A DEPOSITO block without a COMP id (the vision could not read one) is
--   still a receipt with an amount, a via and a reference, and the panel
--   shows it today. The unique index is partial on comp_id for that reason:
--   two unidentified receipts are two real receipts, while the same comp_id
--   twice on one operation is always the same receipt.
--
-- ROLLBACK: ROLLBACK-156-operation-receipts.sql
-- Guarded by supabase/staging/assertions/operation-receipts.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.remittance_operation_receipts (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_id         uuid NOT NULL REFERENCES public.remittance_operations(id) ON DELETE CASCADE,
  conversation_id      uuid,
  comp_id              text,
  amount               numeric,
  currency             text,
  receipt_status       text,
  recipient            text,
  via                  text,
  reference            text,
  receipt_date         text,
  correct_destination  boolean,
  source               text NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT remittance_operation_receipts_source_chk
    CHECK (source IN ('bot', 'backfill'))
);

-- Same receipt, never twice. Partial because comp_id is nullable.
CREATE UNIQUE INDEX IF NOT EXISTS remittance_operation_receipts_operation_comp_uk
  ON public.remittance_operation_receipts (operation_id, comp_id)
  WHERE comp_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS remittance_operation_receipts_comp_idx
  ON public.remittance_operation_receipts (comp_id);

CREATE INDEX IF NOT EXISTS remittance_operation_receipts_conv_idx
  ON public.remittance_operation_receipts (conversation_id);

COMMENT ON TABLE public.remittance_operation_receipts IS
  '156. One row per deposit receipt, already parsed out of deals.notes, '
  'linked to the operation the receipt paid. Dual-written by '
  'cerebro_registrar_deposito (source=''bot'') and backfilled from the '
  'existing notes (source=''backfill'') during the eliminate-deals '
  'transition. The notes stay the source of truth until the panel reads '
  'this table.';

-- Same lock-down 037/096 give the internal cerebro tables: revoke PUBLIC and
-- turn RLS on with no policy. No policy means no row is visible to anon or
-- authenticated whatever grants they hold; service_role bypasses RLS.
REVOKE ALL ON public.remittance_operation_receipts FROM PUBLIC;
ALTER TABLE public.remittance_operation_receipts ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- 2. cerebro_parsear_comprobantes — the notes parser
-- ---------------------------------------------------------------------
--
-- Block splitting is 099's, byte for byte: string_to_array/regexp_split_to_array
-- over E'\n---\n', blocks in note order, block_index counting EVERY block
-- (deposit or not) so the index means the same thing it means in
-- cerebro_parsear_beneficiarios (042) and in crm_comprobantes_de_operacion.
-- A block is a receipt when it contains 'DEPOSITO:' — the trailing
-- 'TOTAL DEPOSITADO:' line of a multi-receipt note is NOT one, because
-- 'DEPOSITADO:' does not contain 'DEPOSITO:'.
--
-- Fields, all optional except none: whatever the note did not say is NULL,
-- never guessed. `reference` keeps the text as written ('N/A' included)
-- and `receipt_date` is the text in parentheses when there is one — the
-- note is the only record of either and a wrong type here would be worse
-- than a string.

CREATE OR REPLACE FUNCTION public.cerebro_parsear_comprobantes(p_notes text)
RETURNS TABLE (
  block_index int, comp_id text, amount numeric, currency text,
  receipt_status text, recipient text, via text, reference text,
  receipt_date text, correct_destination boolean
)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_bloques    text[];
  v_b          text;
  v_i          integer := 0;
  v_monto      text;
  v_estado     text;
  v_destino    text;
  v_referencia text;
BEGIN
  v_bloques := regexp_split_to_array(coalesce(p_notes, ''), E'\n---\n');

  FOREACH v_b IN ARRAY v_bloques LOOP
    v_i := v_i + 1;
    CONTINUE WHEN strpos(v_b, 'DEPOSITO:') = 0;

    -- Amount and currency, 099's own patterns: the panel must keep reading
    -- the notes exactly as before, and this parser must not be the one that
    -- changes what a DEPOSITO line means.
    v_monto  := (regexp_match(v_b, 'DEPOSITO: ([0-9][0-9,]*(\.[0-9]+)?) ([A-Z]{3})'))[1];
    -- The status is whatever follows ' - ' on that same line, whole
    -- ('APROBADA', 'VERIFICADA', 'primer envio'): the note's own words,
    -- not a normalized vocabulary this function would have to keep in sync
    -- with n8n. NULL when the line carries no status at all.
    v_estado := (regexp_match(v_b, 'DEPOSITO: [0-9][0-9,]*(\.[0-9]+)? [A-Z]{3} - ([^\n]*)'))[2];

    v_destino := btrim(coalesce(
      (regexp_match(v_b, 'Destino correcto: *([^[:space:]]+)'))[1], ''));

    -- 'Ref: <digits|N/A>[ (<date>)]' — the date is read off the WHOLE Ref
    -- line before the reference is cut at the parenthesis, or it would be
    -- reading the date out of the string that no longer has one.
    v_referencia := btrim(coalesce((regexp_match(v_b, 'Ref: *([^\n]*)'))[1], ''));

    block_index := v_i;
    comp_id     := (regexp_match(v_b, 'COMP-[0-9a-f]{20}'))[1];
    amount      := NULLIF(replace(v_monto, ',', ''), '')::numeric;
    currency    := (regexp_match(v_b, 'DEPOSITO: [0-9][0-9,]*(\.[0-9]+)? ([A-Z]{3})'))[2];
    receipt_status := NULLIF(btrim(v_estado), '');
    recipient   := NULLIF(btrim(coalesce(
                     (regexp_match(v_b, 'Destinatario: *([^\n]*)'))[1], '')), '');
    via         := NULLIF(btrim(regexp_replace(btrim(coalesce(
                     (regexp_match(v_b, 'Via: *([^\n]*)'))[1], '')),
                     ';[[:space:]]*$', '')), '');
    reference   := NULLIF(btrim(split_part(v_referencia, '(', 1)), '');
    receipt_date := NULLIF(btrim(coalesce(
                      (regexp_match(v_referencia, '\(([^)]*)\)'))[1], '')), '');
    correct_destination := CASE upper(v_destino)
                            WHEN 'SI' THEN true
                            WHEN 'NO' THEN false
                            ELSE NULL END;

    RETURN NEXT;
  END LOOP;
END $$;

COMMENT ON FUNCTION public.cerebro_parsear_comprobantes(text) IS
  '156. Parses deals.notes into deposit receipts, splitting blocks exactly '
  'as 099''s crm_comprobantes_de_operacion does. IMMUTABLE: pure regex '
  'parsing, no table access, no I/O.';

REVOKE ALL ON FUNCTION public.cerebro_parsear_comprobantes(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_parsear_comprobantes(text) TO service_role;

-- ---------------------------------------------------------------------
-- 3. cerebro_registrar_deposito — dual write
-- ---------------------------------------------------------------------
--
-- 125's body verbatim, plus one INSERT per write branch, right before its
-- RETURN QUERY. What is inserted is the receipts of the note THIS call
-- received (v_nota), never a re-parse of the whole deal: re-parsing the
-- notes on every receipt would be O(history) and would re-write rows the
-- backfill already covers. ON CONFLICT ... DO NOTHING on the partial
-- (operation_id, comp_id) index is what makes a duplicate comp_id a no-op.
--
-- When the deal has no remittance_operations row the join yields nothing
-- and no receipt is written: there is no operation to link it to, and
-- inventing one is not this function's business.

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
    -- (156) The receipt this call just carried, linked to the operation of
    -- the deal it landed on. Aliased on purpose: this function keeps
    -- `#variable_conflict use_column` and the `deal_id` OUT parameter.
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM public.remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.deal_id = v_ex
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
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
    -- (156) Same dual write as the "movido" branch, on the summed deal's
    -- operation — a second receipt on the same remesa is a second row of
    -- the same operation, never a second operation.
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM public.remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.deal_id = v_suma
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
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

  -- (156) Same dual write as the other two branches, on the operation the
  -- INSERT above just resolved (the trigger's row, or this one's).
  INSERT INTO public.remittance_operation_receipts (
    operation_id, conversation_id, comp_id, amount, currency, receipt_status,
    recipient, via, reference, receipt_date, correct_destination, source)
  SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
         p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
    FROM public.remittance_operations o
   CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
   WHERE o.deal_id = v_id
  ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;

  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

REVOKE EXECUTE ON FUNCTION cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text)
  TO service_role;

-- ---------------------------------------------------------------------
-- 4. Backfill — every receipt already sitting in the notes
-- ---------------------------------------------------------------------
--
-- Same ON CONFLICT as the dual write: re-running this file never
-- duplicates a receipt, and never overwrites a 'bot' row with a
-- 'backfill' one. Blocks with no COMP id are inserted as they are: they
-- are real receipts the panel shows today, and the partial unique index
-- lets them coexist.

INSERT INTO public.remittance_operation_receipts (
  operation_id, conversation_id, comp_id, amount, currency, receipt_status,
  recipient, via, reference, receipt_date, correct_destination, source)
SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
       p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'backfill'
  FROM deals d
  JOIN public.remittance_operations o ON o.deal_id = d.id
  CROSS JOIN LATERAL cerebro_parsear_comprobantes(d.notes) p
 WHERE d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;

NOTIFY pgrst, 'reload schema';