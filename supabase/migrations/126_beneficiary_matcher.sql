-- =====================================================================
-- 126 — Assign a beneficiary to its deposit when a chat has several open
--        operations
--
-- PROBLEM: cerebro_resolver_operacion returns 'ambigua' as soon as a chat has
-- more than one open operation. 'Registrar zelle auto' and 'Registrar
-- beneficiario auto' then register NOTHING, even with complete data (proven
-- on execution 248563: vision read a full Zelle account from a photo).
--   - In 78% of the remesas that ended with no beneficiary (2026-09-14..26)
--     the chat had another open operation at the same time.
--
-- FIX: cerebro_resolver_operacion_beneficiario(conversation, states, account)
-- reads the conversation to decide which operation the account belongs to.
-- It is ported from a prototype that went 11 correct / 0 wrong on real chats,
-- checked against DB beneficiaries and the team's delivery proofs.
--   0 or 1 open operation → exactly cerebro_resolver_operacion's answer.
--   Several:
--     1. Reparto guard: the customer speaks of several people, "a cada",
--        Mexico… → 'ambigua'. One deposit for many people is not decided here.
--     2. Candidates: open remesa operations with no beneficiary yet, or whose
--        beneficiary is this same account. The evidence may point to an
--        operation that already has a DIFFERENT beneficiary; then the answer
--        is 'ambigua', never "the other one" (a correction must not land on
--        the wrong remesa).
--     3. Anchor: the first customer message containing the account. For a
--        photo, the latest customer image.
--     4. Amount: a number written within 3 messages / 3 minutes of the anchor
--        (with usd/zelle/dólar/$/cup, or alone) that equals floor(GYD / usd
--        rate) — or, for a Cuban card, round(GYD × cup rate) — of exactly one
--        operation.
--     5. Proximity: exactly one operation created within 5 minutes of the
--        anchor.
--     6. Rule C (approved by the user 2026-09-27): the newest open operation,
--        if it is a candidate and every other open operation already has a
--        beneficiary or is older than 24 hours.
--     7. Otherwise 'ambigua', as today.
-- The answer keeps the old shape (resultado 'ninguna'/'unica'/'ambigua',
-- operation_id, candidatas) plus `metodo`, so the n8n nodes only swap the
-- function name and pass the account.
--
-- ROLLBACK: DROP FUNCTION cerebro_resolver_operacion_beneficiario(uuid, text[], text);
--           DROP FUNCTION cerebro_mensajes_cliente_normalizados(uuid, timestamptz);
--           (and point the two n8n nodes back to cerebro_resolver_operacion)
-- Guarded by supabase/staging/assertions/beneficiary-matcher.sql
-- =====================================================================

-- The customer's messages of a chat since a moment, in order, normalized:
-- WhatsApp pastes numbers with no-break spaces, bidi marks and non-breaking
-- hyphens, so those become plain spaces/hyphens before anything is read.
CREATE OR REPLACE FUNCTION cerebro_mensajes_cliente_normalizados(p_conversation_id uuid, p_desde timestamptz)
RETURNS TABLE(i integer, t timestamptz, tipo text, txt text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT row_number() OVER (ORDER BY m.created_at, m.id)::int, m.created_at, m.content_type,
         lower(regexp_replace(regexp_replace(coalesce(m.content_text,''),
               '[' || chr(160) || chr(8192) || '-' || chr(8207) || chr(8234) || '-' || chr(8239) || chr(8288) || ']', ' ', 'g'),
               '[' || chr(8208) || '-' || chr(8213) || ']', '-', 'g'))
    FROM messages m
   WHERE m.conversation_id = p_conversation_id AND m.sender_type = 'customer'
     AND m.created_at >= p_desde;
$$;

REVOKE EXECUTE ON FUNCTION cerebro_mensajes_cliente_normalizados(uuid, timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION cerebro_resolver_operacion_beneficiario(
  p_conversation_id uuid, p_estados text[], p_cuenta text)
RETURNS TABLE(resultado text, operation_id uuid, candidatas integer, metodo text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total     integer;
  v_unica     uuid;
  v_cuenta    text;
  v_es_correo boolean;
  v_es_tarjeta boolean;
  v_usd       numeric := crm_tasa_vigente('usd');
  v_cup       numeric := crm_tasa_vigente('gyd');
  v_desde     timestamptz;
  v_anchor_i  integer;
  v_anchor_t  timestamptz;
  v_m         record;
  v_num       text[];
  v_n         numeric;
  v_hit       uuid;
  v_hits      integer;
  v_cand      boolean;
  v_newest    uuid;
BEGIN
  -- 0/1 open operation: identical to cerebro_resolver_operacion.
  SELECT count(*) INTO v_total FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados));
  IF v_total = 0 THEN
    RETURN QUERY SELECT 'ninguna'::text, NULL::uuid, 0, 'ninguna'::text; RETURN;
  ELSIF v_total = 1 THEN
    SELECT o.id INTO v_unica FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed','cancelled')
       AND (p_estados IS NULL OR o.status = ANY(p_estados));
    RETURN QUERY SELECT 'unica'::text, v_unica, 1, 'unica'::text; RETURN;
  END IF;

  -- Several: normalize the account the node is about to register.
  v_cuenta := lower(regexp_replace(coalesce(p_cuenta,''), '\s', '', 'g'));
  v_es_correo := position('@' in v_cuenta) > 0;
  IF NOT v_es_correo THEN
    v_cuenta := regexp_replace(v_cuenta, '\D', '', 'g');
    IF length(v_cuenta) = 11 AND left(v_cuenta, 1) = '1' THEN v_cuenta := substr(v_cuenta, 2); END IF;
  END IF;
  v_es_tarjeta := NOT v_es_correo AND length(v_cuenta) = 16;
  IF v_cuenta = '' THEN
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'sin_cuenta'::text; RETURN;
  END IF;

  -- The customer's messages since the oldest open operation (minus 3 h), in
  -- order, normalized, with their position.
  SELECT min(o.created_at) - interval '3 hours' INTO v_desde FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.status NOT IN ('completed','cancelled');

  -- 1. Reparto guard.
  IF EXISTS (SELECT 1 FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) WHERE txt ~ '(personas|a cada|repart|una de las|mexico|méxico)') THEN
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'reparto'::text; RETURN;
  END IF;

  -- 3. Anchor: first message that contains the account; else latest image.
  SELECT b.i, b.t INTO v_anchor_i, v_anchor_t FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b
   WHERE (v_es_correo AND replace(b.txt, ' ', '') LIKE '%' || v_cuenta || '%')
      OR (NOT v_es_correo AND regexp_replace(b.txt, '\D', '', 'g') LIKE '%' || v_cuenta || '%')
   ORDER BY b.i LIMIT 1;
  IF v_anchor_i IS NULL THEN
    SELECT b.i, b.t INTO v_anchor_i, v_anchor_t FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b WHERE b.tipo = 'image' ORDER BY b.i DESC LIMIT 1;
  END IF;
  IF v_anchor_i IS NULL THEN v_anchor_t := now(); END IF;

  -- 4. Amount written next to the account.
  IF v_anchor_i IS NOT NULL THEN
    FOR v_m IN
      SELECT b.* FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b
       WHERE b.tipo = 'text' AND abs(b.i - v_anchor_i) <= 3
         AND abs(extract(epoch FROM b.t - v_anchor_t)) <= 180
       ORDER BY abs(b.i - v_anchor_i), b.i
    LOOP
      FOR v_num IN
        SELECT regexp_matches(v_m.txt,
          '(?:^|[^0-9.,])([0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]{2,6})(?![0-9])\s*(usd|zelle|d[oó]lar(?:es)?|\$|cup|pesos)?', 'g')
      LOOP
        IF v_num[2] IS NULL AND btrim(v_m.txt) <> btrim(v_num[1])
           AND v_m.txt !~ '(zelle|usd|d[oó]lar|cup|tarjeta|\$)' THEN
          CONTINUE;
        END IF;
        v_n := replace(replace(v_num[1], '.', ''), ',', '')::numeric;
        SELECT count(*), min(o.id::text)::uuid INTO v_hits, v_hit FROM remittance_operations o
         WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
           AND o.status NOT IN ('completed','cancelled')
           AND (p_estados IS NULL OR o.status = ANY(p_estados))
           AND ((v_usd > 0 AND floor(o.quoted_source_amount / v_usd) = v_n)
                OR (v_es_tarjeta AND v_cup > 0 AND round(o.quoted_source_amount * v_cup) = v_n));
        IF v_hits = 1 THEN
          SELECT NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente')
              OR EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente'
                          AND (lower(coalesce(rb.zelle_account,'')) = v_cuenta
                               OR regexp_replace(coalesce(rb.zelle_account, rb.card_number, ''), '\D', '', 'g') IN (v_cuenta, '1' || v_cuenta)))
            INTO v_cand;
          IF v_cand THEN
            RETURN QUERY SELECT 'unica'::text, v_hit, v_total, 'monto'::text; RETURN;
          END IF;
          RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'monto_apunta_a_otra'::text; RETURN;
        END IF;
      END LOOP;
    END LOOP;
  END IF;

  -- 5. Proximity: exactly one open remesa created within 5 minutes.
  SELECT count(*), min(o.id::text)::uuid INTO v_hits, v_hit FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
     AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados))
     AND abs(extract(epoch FROM o.created_at - v_anchor_t)) <= 300;
  IF v_hits = 1 THEN
    SELECT NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente')
        OR EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente'
                    AND (lower(coalesce(rb.zelle_account,'')) = v_cuenta
                         OR regexp_replace(coalesce(rb.zelle_account, rb.card_number, ''), '\D', '', 'g') IN (v_cuenta, '1' || v_cuenta)))
      INTO v_cand;
    IF v_cand THEN
      RETURN QUERY SELECT 'unica'::text, v_hit, v_total, 'cercania'::text; RETURN;
    END IF;
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'cercania_apunta_a_otra'::text; RETURN;
  END IF;

  -- 6. Rule C.
  SELECT o.id INTO v_newest FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
     AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados))
   ORDER BY o.created_at DESC LIMIT 1;
  IF v_newest IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_newest AND rb.status = 'vigente')
     AND NOT EXISTS (
       SELECT 1 FROM remittance_operations o
        WHERE o.conversation_id = p_conversation_id AND o.id <> v_newest
          AND o.status NOT IN ('completed','cancelled')
          AND (p_estados IS NULL OR o.status = ANY(p_estados))
          AND o.created_at >= now() - interval '24 hours'
          AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = o.id AND rb.status = 'vigente'))
  THEN
    RETURN QUERY SELECT 'unica'::text, v_newest, v_total, 'regla_c'::text; RETURN;
  END IF;

  RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'sin_evidencia'::text;
END $$;

COMMENT ON FUNCTION cerebro_resolver_operacion_beneficiario(uuid, text[], text) IS
  '126. Like cerebro_resolver_operacion, but with several open operations it '
  'reads the conversation (amount, proximity, rule C) to pick the one the '
  'beneficiary belongs to; never over another operation''s different '
  'beneficiary; reparto stays ambiguous.';

REVOKE EXECUTE ON FUNCTION cerebro_resolver_operacion_beneficiario(uuid, text[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_resolver_operacion_beneficiario(uuid, text[], text) TO service_role;

NOTIFY pgrst, 'reload schema';
