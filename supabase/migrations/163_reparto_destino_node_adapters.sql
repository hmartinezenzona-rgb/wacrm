-- =====================================================================
-- 163 — reparto + USD destination: the last two node-contract adapters
--
-- WU4c of eliminate-deals. 161 landed the deal-free operation creator and
-- 162 the four deal-free beneficiary writers. This migration replaces the
-- decision logic of the last two nodes that still write into `deals`, with
-- two SQL functions that decide and write directly against
-- remittance_operations / remittance_beneficiaries:
--
--   n8n node                      arity  -> function
--   registrar_reparto_multiple    11     -> cerebro_registrar_reparto_multiple(uuid, text x9, text)
--   marcar_destino_usd             3     -> cerebro_marcar_destino_usd(uuid, text, text)
--
-- Argument order is the node's own binding order, so WU5's swap is
-- mechanical: $1..$n of the node become the function arguments in order.
-- Return shape is TABLE(id uuid, accion text) for both, with a NULL id on
-- every err / falta / ambiguo / repetida branch — exactly as today.
--
-- ---------------------------------------------------------------------
-- SOURCE OF TRUTH
-- ---------------------------------------------------------------------
-- Both bodies are a STRUCTURAL TRANSLATION of the verbatim node SQL frozen
-- in agent-shared/reports/wu4-n8n-writers.md (n5 and n6). Each CTE keeps
-- the node's name and role; only the deal-backed questions were
-- re-expressed against the operation:
--
--   * "which operation is open?"   -> the resolver inlined (162's form),
--                                     status-filtered on the same four
--                                     states the node's ARRAY bound.
--   * "is there already a
--      beneficiary?" / "is it the
--      same data?"                  -> EXISTS a 'vigente' row (see below).
--   * "was this rail already
--      marked?"                     -> remittance_operations.delivery_method
--                                     (see the MARCADO header note).
--   * "nothing to do" / errors /
--      ambiguity                    -> the same accion literals, byte for
--                                     byte, and the same NULL id.
--   * the ambiguous case            -> the same cerebro_registrar_derivacion
--                                     call with the same arguments and the
--                                     same literal.
--
-- Every accion string is copied byte-for-byte from the node SQL (accents,
-- punctuation and trailing characters included) because the bot's
-- customer-facing replies are built from these literals.
--
-- ---------------------------------------------------------------------
-- REPARTO: WHAT THE OLD PATH ACTUALLY WROTE, AND WHAT REPLACES IT
-- ---------------------------------------------------------------------
-- The node appended a "REPARTO ..." block to deals.notes; the 042 trigger
-- reparsed ALL blocks of the deal's notes into remittance_beneficiaries
-- (cerebro_sync_beneficiarios) and then marked every block older than the
-- newest 'reemplazado'. The parsed rows for the reparto block are:
--
--   beneficiary_type = 'multiple_distribution'
--   name             = NULL
--   card_number      = the tarjeta digits      phone  = the LAST 8 celular digits
--   zelle_account    = NULL
--   amount           = the CUP digits          currency = 'CUP'
--   position         = the line number (1,2,3)
--   block_index      = the index of the block inside deals.notes
--   source           = 'notes_parse'           amount_origin = NULL
--   status           = 'vigente'
--
-- These functions write those rows directly, at the columns the parser
-- produced, so the resulting rows are indistinguishable from the parsed
-- ones — the same approach 162 took for the single-beneficiary nodes.
--
-- "WHICH BLOCK INDEX" WITHOUT NOTES. The old number was the count of
-- blocks in deals.notes, which includes blocks that produced no
-- beneficiary rows (a "DEPOSITO: ..." preamble, a "BENEFICIARIO" block).
-- With no notes it can only be the next generation on that operation:
-- coalesce(max(block_index), 0) + 1 — exactly 162's rule. It agrees with
-- the old number whenever the notes held no non-beneficiary block, and the
-- parity harness runs, and records, the one branch where the two differ
-- (block_index only; see the assertion).
--
-- NOT WRITTEN TO NOTES. There is no notes column to write. The block's
-- HEADER ('REPARTO ENTRE VARIOS BENEFICIARIOS' vs the '... ACTUALIZADO ...'
-- variant, chosen from the node's `tiene_benef`) is therefore dropped:
-- cerebro_parsear_beneficiarios selects its REPARTO branch with
-- `^REPARTO` and reads the per-line `N) Tarjeta: ... ` rows, so the header
-- wording never reached a column. Nothing else reads deals.notes. The
-- header is unobservable in the deal-free world by construction, not by
-- assumption — the harness diffs the rows the header used to sit next to.
--
-- IDEMPOTENCY LOG. Reproduced verbatim: same idempotency_key expression,
-- same tool_name, same execution_id, same jsonb arguments, same
-- ON CONFLICT (idempotency_key) DO NOTHING. Every write branch is gated on
-- `EXISTS (SELECT 1 FROM reg)`, which is what the node's `repetida`
-- branch tests. See "THIS TURN" below.
--
-- ---------------------------------------------------------------------
-- "THIS TURN" — what the reparto dedupe is scoped to
-- ---------------------------------------------------------------------
-- The node's `repetida` branch is `WHERE NOT EXISTS (SELECT 1 FROM reg)`,
-- and `reg` is an INSERT into tool_execution_log with
--   idempotency_key = <execution_id> || ':registrar_reparto_multiple:' ||
--                     md5(concatenation of all 9 data args)
-- `ON CONFLICT (idempotency_key) DO NOTHING RETURNING id`.
-- tool_execution_log.idempotency_key is UNIQUE. So `reg` returns a row
-- only the FIRST time that exact key is used, ever.
--
--   * Same execution (turn) + same args  -> key collides -> reg empty ->
--     `repetida`.
--   * New execution (new turn) + same args -> different execution_id ->
--     different key -> reg returns a row -> the reparto is applied again
--     (the block is rewritten; there is no cross-turn dedupe).
--
-- So "this turn" resolves to ONE n8n workflow execution — the value of
-- `$execution.id`, i.e. one inbound message turn — and to nothing else. It
-- never resolved to the notes, and it never resolved to the operation's
-- history. Unchanged by this migration: the node binds $execution.id as
-- p_execution_id and this function builds the identical key from it, so the
-- dedupe is bit-for-bit the same scope it had before. The brief's
-- "the old implementation reached that through the notes it had just
-- written" is not what the frozen node SQL does; the notes played no part
-- in `repetida`. Assertion case `reparto / repetida` exercises this.
--
-- ---------------------------------------------------------------------
-- MARCADO: WHY THIS IS NOT A WRAPPER OVER 157, AND WHICH CONTRACT IT HAS
-- ---------------------------------------------------------------------
-- 157 (cerebro_registrar_destino / cerebro_detectar_destino) and this node
-- implement RELATED BUT DIFFERENT contracts. The node's contract is the one
-- WU5 depends on, so THIS function reproduces the NODE, not 157:
--
--   1. RAIL VALIDATION. The node does `lower($2) LIKE 'trop%' / 'cl%' /
--      'efec%'` on a single token and always yields a rail or NULL. 157
--      runs whole-word regexes over a whole turn of customer text and
--      returns NULL when the turn names BOTH rails or NEITHER. Different
--      inputs entirely: the node sees a normalised keyword from the model,
--      157 sees the customer's sentence. Measured in the harness's
--      `RAIL` report block.
--   2. ADMIN LOCKS. 157 refuses to re-type a rail a human locked
--      (`admin_locked_fields ? 'delivery_method'`). The node has no such
--      check, and it does not need one: the 096 BEFORE UPDATE guard
--      (remittance_operations_lock_guard) already suppresses an automation
--      write to a locked delivery_method, for the node's write and for
--      this function's write alike. This function therefore adds NO lock
--      check — adding one would CHANGE the node's observable output as the
--      harness measures it. Measured in the harness's
--      `LOCK` report block.
--   3. HOW MANY OPEN OPERATIONS. 157 only ever touches the conversation's
--      single open operation; with two it records the pending row and
--      applies nothing. The node creates a NEW remesa when there are ZERO
--      open operations (its `ins` branch), and returns the `ambiguo`
--      literal when there are TWO OR MORE (its `res` resolver reports
--      'ambigua' and `ins` is gated on `resultado <> 'ambigua'`). This
--      function reproduces exactly that. Measured in the harness's
--      `ZERO-OPS` report block and case `marcar / ambigua`.
--
-- WHERE THE DESTINATION LIVES NOW. The node's whole observable effect on
-- the database was `ENTREGA EN USD: <tipo>` appended to deals.notes, which
-- the `cerebro_sync_benef_trigger` deal trigger translated into (042 first,
-- redefined by 151, which is the live body)
--     UPDATE remittance_operations
--        SET delivery_method = coalesce(<notes marker>, <first
--            vigente beneficiary_type>, delivery_method)
-- where 151 line 65 matches `ENTREGA EN USD: (Clasica|Tropical|Efectivo)`
-- and line 77 turns `Efectivo` into the literal `efectivo_usd`.
-- With no deals there is no notes marker; its surviving carrier is the
-- operation's own delivery_method. This function sets
--     delivery_method = coalesce(<marker(t)>,
--                                <first vigente beneficiary_type>,
--                                delivery_method)
-- i.e. the 151 expression with the notes marker replaced by the rail being
-- marked — and it fires the SAME 096 guard as the old trigger's UPDATE did.
--
-- `<marker(t)>` is not `lower(t)` for all three rails. 151 line 77 is
--     v_usd := CASE WHEN v_usd = 'Efectivo' THEN 'efectivo_usd'
--                   ELSE lower(v_usd) END;
-- so the live notes marker for Efectivo is the literal `efectivo_usd`, not
-- `efectivo`. Measured: a deal carrying `ENTREGA EN USD: Efectivo` ends with
-- `delivery_method = 'efectivo_usd'` (harness cases `ins_efectivo`,
-- `upd_efectivo`, `sin_cambio_efectivo`). An earlier draft of this file
-- asserted the opposite and the harness caught it.
--
-- THE ONE ACCION DIVERGENCE, MEASURED. The node's "already marked" test is
-- `deals.notes LIKE '%ENTREGA EN USD: <t>%'`. The deal-free equivalent is
-- `delivery_method = marker(t)`. The two agree except when the operation
-- was ALREADY typed with a rail by a path that wrote no notes marker —
-- i.e. 157 itself, which sets delivery_method directly. There the node
-- returns 'destino marcado: ...' and this function returns 'sin cambios:
-- ese destino ya estaba marcado'; the resulting DB state is IDENTICAL
-- (delivery_method unchanged in both). The harness runs that case
-- (`marcar / divergencia_ya_tipado`) and asserts that the accion is the ONLY
-- difference. It is reported, not hidden: it changes one customer-facing
-- reply in that one scenario.
--
-- ---------------------------------------------------------------------
-- WHY cerebro_aplicar_reparto (127/129/130) WAS NOT REUSED
-- ---------------------------------------------------------------------
-- Confirmed live on staging: the body is 130's (carries both the 129
-- `v_n_cup` mixed-currency branch and the 130 `63[0-9]{6}` phone rule). It
-- is operation-keyed, as the brief expected, but its CONTRACT is a
-- different, stricter one, and its output is a jsonb verdict — so it is not
-- a drop-in for the node on any axis the harness measures:
--
--   * it refuses a reparto whose amounts do not add up EXACTLY to the
--     deposit (motivo 'suma_no_cuadra'); the node has no amount check at
--     all beyond "non-empty digits";
--   * it refuses a card phone that is not `^(5[0-9]{7}|63[0-9]{6})$`; the
--     node accepts any 8 digits;
--   * it types rows 'cuban_card'/'zelle' with amount_origin 'manual' and
--     source 'reparto_auto'; the parser typed them 'multiple_distribution',
--     amount_origin NULL, source 'notes_parse';
--   * it honours the `beneficiaries` admin lock; the node does not;
--   * it returns jsonb, not the node's `accion` text.
--
-- Reusing it as the write would change the rows AND refuse valid node
-- input. Both halves are measured, not asserted, by the harness's `127`
-- report block: on a 40000 reparto against a 120000 deposit it prints
-- `{"motivo":"suma_no_cuadra","aplicado":false}` and writes no rows,
-- while the same data through the node contract writes both rows with
-- `tipo='multiple_distribution'`.
--
-- ---------------------------------------------------------------------
-- DELIBERATELY NOT DONE HERE
-- ---------------------------------------------------------------------
-- * No deals / pipelines / pipeline_stages read or write anywhere.
-- * The two ai_tool nodes called cerebro_resolver_operacion($1::uuid,
--   ARRAY[...]) — the two-argument overload. That overload is NOT in the
--   working tree nor in any reachable git history (drift documented at
--   097:38-53); it exists only on staging, with p_estados DEFAULT NULL, so
--   even the one-argument call is ambiguous there (42725). Both bodies are
--   INLINED here, exactly as 162 inlined them, with the same four-state
--   filter carried explicitly.
-- * The reparto path did not reproduce the 042 trigger's OPERATION-level
--   delivery_method side effect, for the same reason 162 did not: it
--   belongs to the deal-keyed trigger and disappears with deals. The
--   harness prints it as a measured GAP.
-- * No trigger is added. Nothing is dropped or redefined.
--
-- ROLLBACK: ROLLBACK-163-reparto-destino-node-adapters.sql
-- ASSERTION: supabase/staging/assertions/reparto-destino-node-adapters.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- n5 — registrar_reparto_multiple
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cerebro_registrar_reparto_multiple(
  p_conversation_id uuid,
  p_tarjeta1        text,
  p_celular1        text,
  p_cup1            text,
  p_tarjeta2        text,
  p_celular2        text,
  p_cup2            text,
  p_tarjeta3        text,
  p_celular3        text,
  p_cup3            text,
  p_execution_id    text
) RETURNS TABLE(id uuid, accion text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  WITH res AS (
    -- Inlined cerebro_resolver_operacion(uuid, text[]): see the header.
    SELECT CASE WHEN count(*) = 0 THEN 'ninguna'
                WHEN count(*) = 1 THEN 'unica'
                ELSE 'ambigua' END AS resultado,
           CASE WHEN count(*) = 1
                THEN (SELECT o.id FROM remittance_operations o
                       WHERE o.conversation_id = p_conversation_id
                         AND o.status NOT IN ('completed','cancelled')
                         AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])
                       LIMIT 1)
           END AS operation_id
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed','cancelled')
       AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])
  ),
  idem AS (
    SELECT p_execution_id || ':registrar_reparto_multiple:'
           || md5(coalesce(p_tarjeta1,'')||'|'||coalesce(p_celular1,'')||'|'||coalesce(p_cup1,'')||'|'
                  ||coalesce(p_tarjeta2,'')||'|'||coalesce(p_celular2,'')||'|'||coalesce(p_cup2,'')||'|'
                  ||coalesce(p_tarjeta3,'')||'|'||coalesce(p_celular3,'')||'|'||coalesce(p_cup3,'')) AS k
  ),
  reg AS (
    INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                    conversation_id, operation_id, arguments)
    SELECT (SELECT k FROM idem), 'registrar_reparto_multiple', p_execution_id,
           p_conversation_id, (SELECT operation_id FROM res),
           jsonb_build_array(to_jsonb(p_tarjeta1::text), to_jsonb(p_celular1::text), to_jsonb(p_cup1::text),
                             to_jsonb(p_tarjeta2::text), to_jsonb(p_celular2::text), to_jsonb(p_cup2::text),
                             to_jsonb(p_tarjeta3::text), to_jsonb(p_celular3::text), to_jsonb(p_cup3::text))
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING 1
  ),
  p AS (
    SELECT regexp_replace(COALESCE(p_tarjeta1,''), '[^0-9]', '', 'g') AS t1,
           right(regexp_replace(COALESCE(p_celular1,''), '[^0-9]', '', 'g'), 8) AS c1,
           regexp_replace(COALESCE(p_cup1,''), '[^0-9]', '', 'g') AS m1,
           regexp_replace(COALESCE(p_tarjeta2,''), '[^0-9]', '', 'g') AS t2,
           right(regexp_replace(COALESCE(p_celular2,''), '[^0-9]', '', 'g'), 8) AS c2,
           regexp_replace(COALESCE(p_cup2,''), '[^0-9]', '', 'g') AS m2,
           regexp_replace(COALESCE(p_tarjeta3,''), '[^0-9]', '', 'g') AS t3,
           right(regexp_replace(COALESCE(p_celular3,''), '[^0-9]', '', 'g'), 8) AS c3,
           regexp_replace(COALESCE(p_cup3,''), '[^0-9]', '', 'g') AS m3
  ),
  val AS (
    SELECT (p.t1 ~ '^[0-9]{16}$' AND p.c1 ~ '^[0-9]{8}$' AND p.m1 <> ''
            AND p.t2 ~ '^[0-9]{16}$' AND p.c2 ~ '^[0-9]{8}$' AND p.m2 <> ''
            AND (p.t3 = '' OR (p.t3 ~ '^[0-9]{16}$' AND p.c3 ~ '^[0-9]{8}$' AND p.m3 <> ''))) AS ok
      FROM p
  ),
  abierto AS (
    SELECT res.operation_id AS op_id
      FROM res
     WHERE res.operation_id IS NOT NULL
  ),
  filas AS (
    -- The 2 or 3 beneficiaries the parser would have produced, in order.
    SELECT f.pos, f.tarjeta, f.celular, f.monto
      FROM p
      CROSS JOIN LATERAL (VALUES
        (1, p.t1, p.c1, p.m1),
        (2, p.t2, p.c2, p.m2),
        (3, p.t3, p.c3, p.m3)
      ) AS f(pos, tarjeta, celular, monto)
     WHERE f.pos < 3 OR p.t3 <> ''
  ),
  upd_marca AS (
    UPDATE remittance_beneficiaries
       SET status = 'reemplazado',
           replaced_at = coalesce(replaced_at, now())
     WHERE operation_id = (SELECT op_id FROM abierto)
       AND (SELECT ok FROM val) AND EXISTS (SELECT 1 FROM reg)
       AND status = 'vigente'
    RETURNING 1
  ),
  upd AS (
    -- One accion row per call, as the node's deals UPDATE produced one row.
    SELECT a.op_id AS id,
           'reparto registrado en el envio abierto' AS accion
      FROM abierto a
     WHERE (SELECT ok FROM val) AND EXISTS (SELECT 1 FROM reg)
  ),
  upd_filas AS (
    -- The write itself, one row per beneficiary. Data-modifying CTEs run
    -- whether or not they are referenced, so this needs no consumer.
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      amount, currency, position, block_index, source, status)
    SELECT a.op_id, 'multiple_distribution', NULL, f.tarjeta, f.celular, NULL,
           NULLIF(f.monto, '')::numeric, 'CUP', f.pos,
           (SELECT coalesce(max(b.block_index), 0) + 1
              FROM remittance_beneficiaries b WHERE b.operation_id = a.op_id),
           'notes_parse', 'vigente'
      FROM abierto a
      CROSS JOIN filas f
     WHERE (SELECT ok FROM val) AND EXISTS (SELECT 1 FROM reg)
    RETURNING 1
  ),
  nueva AS (
    SELECT cerebro_crear_operacion(p_conversation_id) AS id
     WHERE NOT EXISTS (SELECT 1 FROM abierto)
       AND (SELECT resultado FROM res) <> 'ambigua'
       AND (SELECT ok FROM val) AND EXISTS (SELECT 1 FROM reg)
  ),
  ins AS (
    SELECT n.id, 'envio nuevo creado con reparto' AS accion
      FROM nueva n
  ),
  ins_filas AS (
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      amount, currency, position, block_index, source, status)
    SELECT n.id, 'multiple_distribution', NULL, f.tarjeta, f.celular, NULL,
           NULLIF(f.monto, '')::numeric, 'CUP', f.pos, 1,
           'notes_parse', 'vigente'
      FROM nueva n
      CROSS JOIN filas f
    RETURNING 1
  ),
  err AS (
    SELECT NULL::uuid AS id,
           'ERROR: faltan datos o algun numero no es valido. Pide al cliente los datos que falten, no inventes nada.' AS accion
     WHERE NOT (SELECT ok FROM val)
  ),
  ambiguo AS (
    SELECT NULL::uuid AS id,
           'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
      FROM cerebro_registrar_derivacion(
             p_conversation_id,
             'Hay varias operaciones abiertas y el caso requiere revisión humana.',
             'operacion_ambigua',
             (SELECT resultado FROM res) = 'ambigua') d
  ),
  repetida AS (
    SELECT NULL::uuid AS id,
           'sin cambios: ese mismo reparto ya se registro en este turno' AS accion
     WHERE NOT EXISTS (SELECT 1 FROM reg)
  )
  SELECT * FROM upd
  UNION ALL SELECT * FROM ins
  UNION ALL SELECT * FROM err
  UNION ALL SELECT * FROM ambiguo
  UNION ALL SELECT * FROM repetida;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_registrar_reparto_multiple(uuid, text, text, text, text, text, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_reparto_multiple(uuid, text, text, text, text, text, text, text, text, text, text)
  TO service_role;


-- ---------------------------------------------------------------------
-- n6 — marcar_destino_usd
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cerebro_marcar_destino_usd(
  p_conversation_id uuid,
  p_tipo            text,
  p_execution_id    text
) RETURNS TABLE(id uuid, accion text)
LANGUAGE plpgsql
VOLATILE
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
        RETURN QUERY SELECT v_op AS id,
          'sin cambios: ese destino ya estaba marcado'::text AS accion;
      ELSE
        UPDATE remittance_operations o
           SET delivery_method = coalesce(v_marker, v_ben, o.delivery_method)
         WHERE o.id = v_op
           AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, v_ben, o.delivery_method);
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
    RETURN QUERY SELECT v_nuevo AS id,
      ('envio nuevo creado, entrega en USD por ' || v_t)::text AS accion;
  END IF;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_marcar_destino_usd(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_marcar_destino_usd(uuid, text, text)
  TO service_role;

NOTIFY pgrst, 'reload schema';
