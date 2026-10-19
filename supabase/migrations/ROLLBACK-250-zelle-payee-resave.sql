-- ROLLBACK of 250_zelle_payee_resave.sql: restores cerebro_resolver_operacion_beneficiario exactly as staging had it on
-- 2026-10-19 (the 223 body). The ACL is untouched by CREATE OR REPLACE. Payees already written stay where they are.

CREATE OR REPLACE FUNCTION public.cerebro_resolver_operacion_beneficiario(p_conversation_id uuid, p_estados text[], p_cuenta text)
 RETURNS TABLE(resultado text, operation_id uuid, candidatas integer, metodo text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- (213) A visa and a combo are never the remesa target (the writers refuse them): they are not candidates here.
  -- (223) Nor is a mobile balance.
  -- 0/1 open operation: identical to cerebro_resolver_operacion.
  SELECT count(*) INTO v_total FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados));
  IF v_total = 0 THEN
    RETURN QUERY SELECT 'ninguna'::text, NULL::uuid, 0, 'ninguna'::text; RETURN;
  ELSIF v_total = 1 THEN
    SELECT o.id INTO v_unica FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
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
   WHERE o.conversation_id = p_conversation_id AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled');

  -- 1. Reparto guard.
  IF EXISTS (SELECT 1 FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) WHERE txt ~ '(personas|a cada|repart|una de las|mexico|méxico)') THEN
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'reparto'::text; RETURN;
  END IF;

  -- 3. Anchor: the MOST RECENT message that contains the account (133); else latest image.
  --    A customer who reuses an account for a new remesa writes it again: the first time it
  --    appeared belongs to the OLD remesa (1727ef31, de846b30).
  SELECT b.i, b.t INTO v_anchor_i, v_anchor_t FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b
   WHERE (v_es_correo AND replace(b.txt, ' ', '') LIKE '%' || v_cuenta || '%')
      OR (NOT v_es_correo AND regexp_replace(b.txt, '\D', '', 'g') LIKE '%' || v_cuenta || '%')
   ORDER BY b.i DESC LIMIT 1;
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
           AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
           AND (p_estados IS NULL OR o.status = ANY(p_estados))
           -- (215) A Zelle account is paired by the tiered USD of the deposit; a card (Clasica, Tropical) by the single rate.
           AND ((NOT v_es_tarjeta AND (SELECT z.usd FROM cerebro_zelle_cotizar_op(o.id, o.quoted_source_amount) z) = v_n)
                OR (v_es_tarjeta AND v_usd > 0 AND floor(o.quoted_source_amount / v_usd) = v_n)
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
     AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
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
     AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados))
   ORDER BY o.created_at DESC LIMIT 1;
  IF v_newest IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_newest AND rb.status = 'vigente')
     AND NOT EXISTS (
       SELECT 1 FROM remittance_operations o
        WHERE o.conversation_id = p_conversation_id AND o.id <> v_newest
          AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
          AND (p_estados IS NULL OR o.status = ANY(p_estados))
          AND o.created_at >= now() - interval '24 hours'
          AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = o.id AND rb.status = 'vigente'))
  THEN
    RETURN QUERY SELECT 'unica'::text, v_newest, v_total, 'regla_c'::text; RETURN;
  END IF;

  RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'sin_evidencia'::text;
END $function$
;

NOTIFY pgrst, 'reload schema';
