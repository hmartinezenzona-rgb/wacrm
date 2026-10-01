-- =====================================================================
-- 162 — deal-free beneficiary writers (card + zelle, auto rail + ai_tool)
--
-- WU4b of eliminate-deals. Replaces the DECISION LOGIC of four n8n nodes
-- with four SQL functions that decide and write directly against
-- remittance_beneficiaries, with NO deals row anywhere in the path.
-- WU5 swaps each node's query for `SELECT <function>($1, …)` later.
--
--   n8n node                     arity  -> function                          family
--   Registrar beneficiario auto   4     -> cerebro_registrar_beneficiario_auto(uuid,text,text,text)  card, auto rail
--   gestionar_beneficiario        5     -> cerebro_gestionar_beneficiario(uuid,text,text,text,text)  card, ai_tool
--   Registrar zelle auto          4     -> cerebro_registrar_zelle_auto(uuid,text,text,text)          zelle, auto rail
--   registrar_beneficiario_zelle  4     -> cerebro_registrar_beneficiario_zelle(uuid,text,text,text)  zelle, ai_tool
--
-- Argument order is the node's own binding order, so the swap is
-- mechanical: $1..$n of the node become the function arguments in order.
-- Return shape is TABLE(id uuid, accion text) for all four, with a NULL
-- id on every falta / ambiguo branch — exactly as today.
--
-- Each body is one data-modifying CTE chain, so the plpgsql wrapper is
-- `BEGIN RETURN QUERY … END;` and nothing else.
--
-- ---------------------------------------------------------------------
-- SOURCE OF TRUTH
-- ---------------------------------------------------------------------
-- The four bodies below are a STRUCTURAL TRANSLATION of the verbatim node
-- SQL frozen in agent-shared/reports/wu4-n8n-writers.md (n1..n4). Each CTE
-- keeps the node's name and role; only the deal-backed questions were
-- re-expressed against remittance_beneficiaries:
--
--   * "is there already a beneficiary?"  -> EXISTS a 'vigente' row on the
--                                            resolved operation.
--   * "is it the same data?"             -> the 'vigente' row's card/phone
--                                            (card nodes) or name/zelle
--                                            account (zelle nodes) equal
--                                            what the node is about to
--                                            register, using exactly the
--                                            normalization the node used:
--                                            card nodes compare RAW (the
--                                            old LIKE compared raw $2/$3
--                                            against the composed note);
--                                            zelle nodes compare the name
--                                            raw and the account through
--                                            the same US-number CASE the
--                                            node carried.
--   * "nothing to do"                    -> the same `sin cambios: …`
--                                            accion literal, byte-identical.
--   * the ambiguous case                 -> the same cerebro_registrar_
--                                            derivacion(...) call with the
--                                            same arguments and the same
--                                            literal.
--
-- Every accion string is copied byte-for-byte from the node SQL (accents,
-- punctuation and trailing characters included) because the bot's
-- customer-facing replies are built from these literals.
--
-- ---------------------------------------------------------------------
-- WRITES: structured, not notes
-- ---------------------------------------------------------------------
-- The old path appended a BENEFICIARIO block to deals.notes and let
-- trg_sync_z_benef_desde_deal -> cerebro_sync_beneficiarios (042) parse it
-- into remittance_beneficiaries. These functions write the row directly,
-- at the same columns the parser produced, so the resulting row is
-- indistinguishable from the parsed one:
--
--   beneficiary_type : 'cuban_card' / 'zelle'
--   name             : NULL for the auto card rail; the raw name for the
--                      tool nodes (NULL when empty)
--   card_number/phone: raw $tarjeta / $celular (the parser keeps the digit
--                      run, which for a real 16/8-digit input is the input)
--   zelle_account    : the normalized account
--   position         : 1 (the parser's value for a single beneficiary)
--   block_index      : coalesce(max(block_index),0)+1 — a generation
--                      counter that never collides with rb_unico_por_bloque
--                      (operation_id, block_index, position). In the old
--                      world this number was the index of the block inside
--                      deals.notes; with no notes it can only be the next
--                      generation, which is why the harness records the one
--                      branch where the two differ (see the assertion).
--   amount/currency  : NULL (these nodes never set an amount)
--   source           : 'notes_parse' — kept for column-by-column parity
--                      with the row the 042 parser wrote. It is a free-text
--                      column with no CHECK; nothing filters on it.
--   status           : 'vigente'
--
-- When the data differs and a beneficiary already exists, the old path
-- marked the previous row 'reemplazado' (replaced_at = now()) and inserted
-- the new one. These functions do the same.
--
-- ---------------------------------------------------------------------
-- IDEMPOTENCY LOG
-- ---------------------------------------------------------------------
-- Every node wrote a tool_execution_log row first. Reproduced verbatim:
-- same idempotency_key expression, same tool_name, same execution_id,
-- same jsonb arguments, same ON CONFLICT (idempotency_key) DO NOTHING.
-- The card auto node's `limpiar` side effect (DELETE FROM
-- cerebro_beneficiario_parcial WHERE conversation_id = $1) is reproduced
-- too — it is present only in that node.
--
-- ---------------------------------------------------------------------
-- RESOLVERS
-- ---------------------------------------------------------------------
-- The two auto-rail nodes call cerebro_resolver_operacion_beneficiario(
-- uuid, text[], text) (133), which exists in the repo and is unambiguous —
-- used as-is.
--
-- The two ai_tool nodes called cerebro_resolver_operacion($1::uuid,
-- ARRAY[…]) — the two-argument overload. That overload is NOT in the
-- working tree nor in any reachable git history (drift documented at
-- 097:38-53); it exists only on staging. Depending on it would make this
-- migration unreproducible. The counting body of both overloads is
-- identical (0 -> 'ninguna', 1 -> 'unica' + id, more -> 'ambigua' + NULL
-- id), so it is INLINED here, with the status filter carried explicitly.
-- The one-argument call is not used anywhere: on staging it is ambiguous
-- (42725, the live 2-arg overload has a default).
--
-- ---------------------------------------------------------------------
-- DELIBERATELY NOT DONE HERE
-- ---------------------------------------------------------------------
-- * No deals / pipelines / pipeline_stages read or write anywhere.
-- * The old deal path also let trg_sync_z_benef_desde_deal update the
--   OPERATION's delivery_method (to the beneficiary type). These functions
--   do not reproduce that side effect: it belongs to the 042 trigger, which
--   is deal-keyed and disappears with deals. The parity assertion measures
--   the difference and records it rather than hiding it.
-- * crm_agregar_beneficiario (123) was NOT reused: it requires amount > 0
--   and a currency, sets source='admin_addition', locks the operation's
--   beneficiaries and writes an audit row — none of which matches an
--   automated node write (whose rows carry no amount). Reusing it would
--   fail with 22023 on every call.
--
-- ROLLBACK: ROLLBACK-162-deal-free-beneficiary-writers.sql
-- ASSERTION: supabase/staging/assertions/deal-free-beneficiary-writers.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- n1 — Registrar beneficiario auto (card, automatic)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cerebro_registrar_beneficiario_auto(
  p_conversation_id uuid,
  p_tarjeta         text,
  p_celular         text,
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
    SELECT * FROM cerebro_resolver_operacion_beneficiario(
      p_conversation_id,
      ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'],
      p_tarjeta)
  ),
  idem AS (
    SELECT p_execution_id || ':Registrar beneficiario auto:'
           || md5(coalesce(p_tarjeta,'')||'|'||coalesce(p_celular,'')) AS k
  ),
  reg AS (
    INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                    conversation_id, operation_id, arguments)
    SELECT (SELECT k FROM idem), 'Registrar beneficiario auto', p_execution_id,
           p_conversation_id, (SELECT operation_id FROM res),
           jsonb_build_array(to_jsonb(p_tarjeta::text), to_jsonb(p_celular::text))
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING 1
  ),
  abierto AS (
    SELECT res.operation_id AS op_id,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b
                    WHERE b.operation_id = res.operation_id
                      AND b.status = 'vigente') AS tiene_benef,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b
                    WHERE b.operation_id = res.operation_id
                      AND b.status = 'vigente'
                      AND b.card_number = p_tarjeta
                      AND b.phone = p_celular) AS mismos_datos
      FROM res
     WHERE res.operation_id IS NOT NULL
  ),
  limpiar AS (
    DELETE FROM cerebro_beneficiario_parcial
     WHERE conversation_id = p_conversation_id
    RETURNING 1
  ),
  upd_marca AS (
    UPDATE remittance_beneficiaries
       SET status = 'reemplazado',
           replaced_at = coalesce(replaced_at, now())
     WHERE operation_id = (SELECT op_id FROM abierto WHERE NOT mismos_datos)
       AND status = 'vigente'
    RETURNING 1
  ),
  upd AS (
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      position, block_index, source, status)
    SELECT a.op_id, 'cuban_card', NULL, p_tarjeta, p_celular, NULL, 1,
           (SELECT coalesce(max(b.block_index), 0) + 1
              FROM remittance_beneficiaries b WHERE b.operation_id = a.op_id),
           'notes_parse', 'vigente'
      FROM abierto a
     WHERE NOT a.mismos_datos
    RETURNING operation_id AS id,
              (SELECT CASE WHEN a.tiene_benef
                           THEN 'beneficiario ACTUALIZADO en el envio abierto'
                           ELSE 'beneficiario agregado al envio abierto' END
                 FROM abierto a) AS accion
  ),
  nueva AS (
    SELECT cerebro_crear_operacion(p_conversation_id) AS id
     WHERE NOT EXISTS (SELECT 1 FROM abierto)
       AND (SELECT resultado FROM res) <> 'ambigua'
  ),
  ins AS (
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      position, block_index, source, status)
    SELECT n.id, 'cuban_card', NULL, p_tarjeta, p_celular, NULL, 1, 1,
           'notes_parse', 'vigente'
      FROM nueva n
    RETURNING operation_id AS id,
              'envio nuevo creado con beneficiario auto' AS accion
  ),
  sin_cambio AS (
    SELECT a.op_id, 'sin cambios: esos datos ya estaban en el envio abierto' AS accion
      FROM abierto a
     WHERE a.mismos_datos
  ),
  ambiguo AS (
    SELECT NULL::uuid AS id,
           'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
      FROM cerebro_registrar_derivacion(
             p_conversation_id,
             'Hay varias operaciones abiertas y el caso requiere revisión humana.',
             'operacion_ambigua',
             (SELECT resultado FROM res) = 'ambigua') d
  )
  SELECT * FROM upd
  UNION ALL SELECT * FROM ins
  UNION ALL SELECT * FROM sin_cambio
  UNION ALL SELECT * FROM ambiguo;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_registrar_beneficiario_auto(uuid, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_beneficiario_auto(uuid, text, text, text)
  TO service_role;


-- ---------------------------------------------------------------------
-- n3 — gestionar_beneficiario (card, ai_tool)
-- ---------------------------------------------------------------------
-- Same decision shape as n1, with the tool's differences: an optional
-- name, the shifted argument order, the plain resolver inlined, no
-- `limpiar`, and the ins accion 'envio nuevo creado'.

CREATE OR REPLACE FUNCTION public.cerebro_gestionar_beneficiario(
  p_conversation_id uuid,
  p_nombre          text,
  p_tarjeta         text,
  p_celular         text,
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
    SELECT p_execution_id || ':gestionar_beneficiario:'
           || md5(coalesce(p_nombre,'')||'|'||coalesce(p_tarjeta,'')||'|'||coalesce(p_celular,'')) AS k
  ),
  reg AS (
    INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                    conversation_id, operation_id, arguments)
    SELECT (SELECT k FROM idem), 'gestionar_beneficiario', p_execution_id,
           p_conversation_id, (SELECT operation_id FROM res),
           jsonb_build_array(to_jsonb(p_nombre::text), to_jsonb(p_tarjeta::text), to_jsonb(p_celular::text))
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING 1
  ),
  abierto AS (
    SELECT res.operation_id AS op_id,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b
                    WHERE b.operation_id = res.operation_id
                      AND b.status = 'vigente') AS tiene_benef,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b
                    WHERE b.operation_id = res.operation_id
                      AND b.status = 'vigente'
                      AND b.card_number = p_tarjeta
                      AND b.phone = p_celular) AS mismos_datos
      FROM res
     WHERE res.operation_id IS NOT NULL
  ),
  upd_marca AS (
    UPDATE remittance_beneficiaries
       SET status = 'reemplazado',
           replaced_at = coalesce(replaced_at, now())
     WHERE operation_id = (SELECT op_id FROM abierto WHERE NOT mismos_datos)
       AND status = 'vigente'
    RETURNING 1
  ),
  upd AS (
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      position, block_index, source, status)
    SELECT a.op_id, 'cuban_card', NULLIF(p_nombre,''), p_tarjeta, p_celular, NULL, 1,
           (SELECT coalesce(max(b.block_index), 0) + 1
              FROM remittance_beneficiaries b WHERE b.operation_id = a.op_id),
           'notes_parse', 'vigente'
      FROM abierto a
     WHERE NOT a.mismos_datos
    RETURNING operation_id AS id,
              (SELECT CASE WHEN a.tiene_benef
                           THEN 'beneficiario ACTUALIZADO en el envio abierto'
                           ELSE 'beneficiario agregado al envio abierto' END
                 FROM abierto a) AS accion
  ),
  nueva AS (
    SELECT cerebro_crear_operacion(p_conversation_id) AS id
     WHERE NOT EXISTS (SELECT 1 FROM abierto)
       AND (SELECT resultado FROM res) <> 'ambigua'
  ),
  ins AS (
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      position, block_index, source, status)
    SELECT n.id, 'cuban_card', NULLIF(p_nombre,''), p_tarjeta, p_celular, NULL, 1, 1,
           'notes_parse', 'vigente'
      FROM nueva n
    RETURNING operation_id AS id, 'envio nuevo creado' AS accion
  ),
  sin_cambio AS (
    SELECT a.op_id, 'sin cambios: esos datos ya estaban en el envio abierto' AS accion
      FROM abierto a
     WHERE a.mismos_datos
  ),
  ambiguo AS (
    SELECT NULL::uuid AS id,
           'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
      FROM cerebro_registrar_derivacion(
             p_conversation_id,
             'Hay varias operaciones abiertas y el caso requiere revisión humana.',
             'operacion_ambigua',
             (SELECT resultado FROM res) = 'ambigua') d
  )
  SELECT * FROM upd
  UNION ALL SELECT * FROM ins
  UNION ALL SELECT * FROM sin_cambio
  UNION ALL SELECT * FROM ambiguo;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_gestionar_beneficiario(uuid, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_gestionar_beneficiario(uuid, text, text, text, text)
  TO service_role;


-- ---------------------------------------------------------------------
-- n2 — Registrar zelle auto (zelle, automatic)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cerebro_registrar_zelle_auto(
  p_conversation_id uuid,
  p_nombre          text,
  p_cuenta          text,
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
    SELECT * FROM cerebro_resolver_operacion_beneficiario(
      p_conversation_id,
      ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'],
      p_cuenta)
  ),
  idem AS (
    SELECT p_execution_id || ':Registrar zelle auto:'
           || md5(coalesce(p_nombre,'')||'|'||coalesce(p_cuenta,'')) AS k
  ),
  reg AS (
    INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                    conversation_id, operation_id, arguments)
    SELECT (SELECT k FROM idem), 'Registrar zelle auto', p_execution_id,
           p_conversation_id, (SELECT operation_id FROM res),
           jsonb_build_array(to_jsonb(p_nombre::text), to_jsonb(p_cuenta::text))
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING 1
  ),
  cuenta AS (
    -- Copied verbatim from the node: a US number ends as 10 bare digits;
    -- e-mails, +<non-1> prefixes and anything unrecognised are left alone.
    SELECT CASE
      WHEN p_cuenta IS NULL THEN NULL
      WHEN p_cuenta LIKE '%@%' THEN btrim(p_cuenta)
      WHEN btrim(p_cuenta) LIKE '+%' AND btrim(p_cuenta) NOT LIKE '+1%' THEN btrim(p_cuenta)
      WHEN length(regexp_replace(p_cuenta, '[^0-9]', '', 'g')) = 11
       AND left(regexp_replace(p_cuenta, '[^0-9]', '', 'g'), 1) = '1'
        THEN right(regexp_replace(p_cuenta, '[^0-9]', '', 'g'), 10)
      WHEN length(regexp_replace(p_cuenta, '[^0-9]', '', 'g')) = 10
       AND left(regexp_replace(p_cuenta, '[^0-9]', '', 'g'), 1) BETWEEN '2' AND '9'
       AND left(regexp_replace(p_cuenta, '[^0-9]', '', 'g'), 1) <> '5'
        THEN regexp_replace(p_cuenta, '[^0-9]', '', 'g')
      ELSE btrim(p_cuenta)
    END AS c
  ),
  abierto AS (
    SELECT res.operation_id AS op_id,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b
                    WHERE b.operation_id = res.operation_id
                      AND b.status = 'vigente') AS tiene_benef,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b
                    WHERE b.operation_id = res.operation_id
                      AND b.status = 'vigente'
                      AND b.name = p_nombre
                      AND b.zelle_account = (SELECT c FROM cuenta)) AS mismos_datos
      FROM res
     WHERE res.operation_id IS NOT NULL
  ),
  falta AS (
    SELECT NULL::uuid AS id,
           'ERROR: hacen falta el nombre Y la cuenta. No se registro nada.' AS accion
     WHERE NULLIF(p_nombre,'') IS NULL OR NULLIF(p_cuenta,'') IS NULL
  ),
  upd_marca AS (
    UPDATE remittance_beneficiaries
       SET status = 'reemplazado',
           replaced_at = coalesce(replaced_at, now())
     WHERE operation_id = (SELECT op_id FROM abierto WHERE NOT mismos_datos)
       AND status = 'vigente'
    RETURNING 1
  ),
  upd AS (
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      position, block_index, source, status)
    SELECT a.op_id, 'zelle', p_nombre, NULL, NULL, (SELECT c FROM cuenta), 1,
           (SELECT coalesce(max(b.block_index), 0) + 1
              FROM remittance_beneficiaries b WHERE b.operation_id = a.op_id),
           'notes_parse', 'vigente'
      FROM abierto a
     WHERE NOT a.mismos_datos
       AND NULLIF(p_nombre,'') IS NOT NULL AND NULLIF(p_cuenta,'') IS NOT NULL
    RETURNING operation_id AS id,
              (SELECT CASE WHEN a.tiene_benef
                           THEN 'beneficiario Zelle ACTUALIZADO en el envio abierto'
                           ELSE 'beneficiario Zelle agregado en el envio abierto' END
                 FROM abierto a) AS accion
  ),
  nueva AS (
    SELECT cerebro_crear_operacion(p_conversation_id) AS id
     WHERE NOT EXISTS (SELECT 1 FROM abierto)
       AND (SELECT resultado FROM res) <> 'ambigua'
       AND NULLIF(p_nombre,'') IS NOT NULL AND NULLIF(p_cuenta,'') IS NOT NULL
  ),
  ins AS (
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      position, block_index, source, status)
    SELECT n.id, 'zelle', p_nombre, NULL, NULL, (SELECT c FROM cuenta), 1, 1,
           'notes_parse', 'vigente'
      FROM nueva n
    RETURNING operation_id AS id, 'envio nuevo creado' AS accion
  ),
  sin_cambio AS (
    SELECT a.op_id, 'sin cambios: esos datos ya estaban en el envio abierto' AS accion
      FROM abierto a
     WHERE a.mismos_datos
  ),
  ambiguo AS (
    SELECT NULL::uuid AS id,
           'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
      FROM cerebro_registrar_derivacion(
             p_conversation_id,
             'Hay varias operaciones abiertas y el caso requiere revisión humana.',
             'operacion_ambigua',
             (SELECT resultado FROM res) = 'ambigua') d
  )
  SELECT * FROM falta
  UNION ALL SELECT * FROM upd
  UNION ALL SELECT * FROM ins
  UNION ALL SELECT * FROM sin_cambio
  UNION ALL SELECT * FROM ambiguo;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_registrar_zelle_auto(uuid, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_zelle_auto(uuid, text, text, text)
  TO service_role;


-- ---------------------------------------------------------------------
-- n4 — registrar_beneficiario_zelle (zelle, ai_tool)
-- ---------------------------------------------------------------------
-- n2 verbatim except: the plain resolver inlined, and the log name.

CREATE OR REPLACE FUNCTION public.cerebro_registrar_beneficiario_zelle(
  p_conversation_id uuid,
  p_nombre          text,
  p_cuenta          text,
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
    SELECT p_execution_id || ':registrar_beneficiario_zelle:'
           || md5(coalesce(p_nombre,'')||'|'||coalesce(p_cuenta,'')) AS k
  ),
  reg AS (
    INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                    conversation_id, operation_id, arguments)
    SELECT (SELECT k FROM idem), 'registrar_beneficiario_zelle', p_execution_id,
           p_conversation_id, (SELECT operation_id FROM res),
           jsonb_build_array(to_jsonb(p_nombre::text), to_jsonb(p_cuenta::text))
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING 1
  ),
  cuenta AS (
    SELECT CASE
      WHEN p_cuenta IS NULL THEN NULL
      WHEN p_cuenta LIKE '%@%' THEN btrim(p_cuenta)
      WHEN btrim(p_cuenta) LIKE '+%' AND btrim(p_cuenta) NOT LIKE '+1%' THEN btrim(p_cuenta)
      WHEN length(regexp_replace(p_cuenta, '[^0-9]', '', 'g')) = 11
       AND left(regexp_replace(p_cuenta, '[^0-9]', '', 'g'), 1) = '1'
        THEN right(regexp_replace(p_cuenta, '[^0-9]', '', 'g'), 10)
      WHEN length(regexp_replace(p_cuenta, '[^0-9]', '', 'g')) = 10
       AND left(regexp_replace(p_cuenta, '[^0-9]', '', 'g'), 1) BETWEEN '2' AND '9'
       AND left(regexp_replace(p_cuenta, '[^0-9]', '', 'g'), 1) <> '5'
        THEN regexp_replace(p_cuenta, '[^0-9]', '', 'g')
      ELSE btrim(p_cuenta)
    END AS c
  ),
  abierto AS (
    SELECT res.operation_id AS op_id,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b
                    WHERE b.operation_id = res.operation_id
                      AND b.status = 'vigente') AS tiene_benef,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b
                    WHERE b.operation_id = res.operation_id
                      AND b.status = 'vigente'
                      AND b.name = p_nombre
                      AND b.zelle_account = (SELECT c FROM cuenta)) AS mismos_datos
      FROM res
     WHERE res.operation_id IS NOT NULL
  ),
  falta AS (
    SELECT NULL::uuid AS id,
           'ERROR: hacen falta el nombre Y la cuenta. No se registro nada.' AS accion
     WHERE NULLIF(p_nombre,'') IS NULL OR NULLIF(p_cuenta,'') IS NULL
  ),
  upd_marca AS (
    UPDATE remittance_beneficiaries
       SET status = 'reemplazado',
           replaced_at = coalesce(replaced_at, now())
     WHERE operation_id = (SELECT op_id FROM abierto WHERE NOT mismos_datos)
       AND status = 'vigente'
    RETURNING 1
  ),
  upd AS (
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      position, block_index, source, status)
    SELECT a.op_id, 'zelle', p_nombre, NULL, NULL, (SELECT c FROM cuenta), 1,
           (SELECT coalesce(max(b.block_index), 0) + 1
              FROM remittance_beneficiaries b WHERE b.operation_id = a.op_id),
           'notes_parse', 'vigente'
      FROM abierto a
     WHERE NOT a.mismos_datos
       AND NULLIF(p_nombre,'') IS NOT NULL AND NULLIF(p_cuenta,'') IS NOT NULL
    RETURNING operation_id AS id,
              (SELECT CASE WHEN a.tiene_benef
                           THEN 'beneficiario Zelle ACTUALIZADO en el envio abierto'
                           ELSE 'beneficiario Zelle agregado en el envio abierto' END
                 FROM abierto a) AS accion
  ),
  nueva AS (
    SELECT cerebro_crear_operacion(p_conversation_id) AS id
     WHERE NOT EXISTS (SELECT 1 FROM abierto)
       AND (SELECT resultado FROM res) <> 'ambigua'
       AND NULLIF(p_nombre,'') IS NOT NULL AND NULLIF(p_cuenta,'') IS NOT NULL
  ),
  ins AS (
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      position, block_index, source, status)
    SELECT n.id, 'zelle', p_nombre, NULL, NULL, (SELECT c FROM cuenta), 1, 1,
           'notes_parse', 'vigente'
      FROM nueva n
    RETURNING operation_id AS id, 'envio nuevo creado' AS accion
  ),
  sin_cambio AS (
    SELECT a.op_id, 'sin cambios: esos datos ya estaban en el envio abierto' AS accion
      FROM abierto a
     WHERE a.mismos_datos
  ),
  ambiguo AS (
    SELECT NULL::uuid AS id,
           'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
      FROM cerebro_registrar_derivacion(
             p_conversation_id,
             'Hay varias operaciones abiertas y el caso requiere revisión humana.',
             'operacion_ambigua',
             (SELECT resultado FROM res) = 'ambigua') d
  )
  SELECT * FROM falta
  UNION ALL SELECT * FROM upd
  UNION ALL SELECT * FROM ins
  UNION ALL SELECT * FROM sin_cambio
  UNION ALL SELECT * FROM ambiguo;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_registrar_beneficiario_zelle(uuid, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_beneficiario_zelle(uuid, text, text, text)
  TO service_role;

NOTIFY pgrst, 'reload schema';
