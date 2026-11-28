-- ROLLBACK of 254_operaciones_mixed_group_id.sql: restores crm_operaciones_de_conversacion exactly as staging had it on
-- 2026-10-20 (live pg_get_functiondef text, without operation_mixed_group_id). The return type changes, so the function is
-- dropped first. Grants are the ones 208 gave it.

DROP FUNCTION public.crm_operaciones_de_conversacion(uuid);

CREATE OR REPLACE FUNCTION public.crm_operaciones_de_conversacion(p_conversation_id uuid)
 RETURNS TABLE(resolver_resultado text, resolver_operation_id uuid, resolver_candidatas integer, operation_id uuid, operation_status text, operation_service_type text, operation_source_currency text, operation_destination_currency text, operation_delivery_method text, operation_deposit_method text, operation_quoted_source_amount numeric, operation_quoted_destination_amount numeric, operation_admin_locked_fields jsonb, operation_created_at timestamp with time zone, operation_completed_at timestamp with time zone, beneficiary_id uuid, beneficiary_type text, beneficiary_name text, beneficiary_card_number text, beneficiary_phone text, beneficiary_zelle_account text, beneficiary_delivery_method text, beneficiary_amount numeric, beneficiary_currency text, beneficiary_position integer, operation_quoted_destination_rate numeric, operation_quoted_destination_origin text, beneficiary_amount_origin text, operation_is_history boolean, operation_beneficiaries_complete boolean, operation_delivery_mode text, operation_delivered_at timestamp with time zone, beneficiary_address text, beneficiary_id_photo_wamid text, beneficiary_id_photo_url text, beneficiary_reference text, beneficiary_contact_phone text, operation_combo_costo_gyd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id            uuid;
  v_resolver_resultado    text;
  v_resolver_operation_id uuid;
  v_resolver_candidatas   integer;
BEGIN
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;
  SELECT c.account_id INTO v_account_id
    FROM conversations c
   WHERE c.id = p_conversation_id;
  -- Same 42501 whether the conversation doesn't exist or belongs to an
  -- account the caller isn't a member of — see 097's file header for why.
  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;
  -- Inlined, NOT called by name — see 097's file header's "WHY THE
  -- RESOLVER LOGIC IS INLINED" section. Unchanged by this migration: the
  -- resolver only ever looks at live (non-terminal) operations, regardless
  -- of the history rows the RETURN QUERY below now also surfaces.
  SELECT count(*) INTO v_resolver_candidatas
    FROM remittance_operations
   WHERE conversation_id = p_conversation_id
     AND status NOT IN ('completed', 'cancelled');
  IF v_resolver_candidatas = 0 THEN
    v_resolver_resultado := 'ninguna';
    v_resolver_operation_id := NULL;
  ELSIF v_resolver_candidatas = 1 THEN
    v_resolver_resultado := 'unica';
    SELECT o.id INTO v_resolver_operation_id
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled');
  ELSE
    v_resolver_resultado := 'ambigua';
    v_resolver_operation_id := NULL;
  END IF;
  RETURN QUERY
  WITH ops AS (
    -- Current open (non-terminal) remesa operations — same set the RPC
    -- has always returned.
    SELECT o.*, false AS is_history
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled')
       AND o.service_type IN ('remesa', 'recarga', 'combo', 'visa', 'saldo')  -- (200) recharges too, (208) combos, (213) visas, (223) mobile balances
    UNION ALL
    -- The 10 most recently completed remesa operations of the same
    -- conversation — read-only history. A completed operation can never
    -- also match the branch above (status is exclusive), so UNION ALL
    -- cannot duplicate a row.
    SELECT h.*, true AS is_history
      FROM (
        SELECT o2.*
          FROM remittance_operations o2
         WHERE o2.conversation_id = p_conversation_id
           AND o2.status = 'completed'
           AND o2.service_type IN ('remesa', 'recarga', 'combo', 'visa', 'saldo')  -- (200), (208), (223)
         ORDER BY o2.completed_at DESC
         LIMIT 10
      ) h
  )
  SELECT
    r.resultado,
    r.operation_id,
    r.candidatas,
    o.id,
    o.status,
    o.service_type,
    o.source_currency,
    o.destination_currency,
    o.delivery_method,
    o.deposit_method,
    o.quoted_source_amount,
    o.quoted_destination_amount,
    o.admin_locked_fields,
    o.created_at,
    o.completed_at,
    b.id,
    b.beneficiary_type,
    b.name,
    b.card_number,
    b.phone,
    b.zelle_account,
    b.delivery_method,
    b.amount,
    b.currency,
    b.position,
    o.quoted_destination_rate,
    o.quoted_destination_origin,
    b.amount_origin,
    o.is_history,
    CASE WHEN o.id IS NULL THEN NULL ELSE crm_beneficiarios_completos(o.id) END,
    o.delivery_mode,
    CASE WHEN o.is_history THEN o.completed_at ELSE NULL END,
    -- (189) a cash recipient (150): address and the ID-card photo, with the URL of the message it came in.
    b.address,
    b.id_photo_wamid,
    (SELECT m.media_url FROM messages m
      WHERE b.id_photo_wamid IS NOT NULL AND m.message_id = b.id_photo_wamid
        AND m.conversation_id = o.conversation_id
      ORDER BY m.created_at DESC LIMIT 1),
    -- (208) A combo recipient: how to get there and the second contact phone; the combo's cost (set by the admin).
    b.reference,
    b.contact_phone,
    o.combo_costo_gyd
  -- A single synthetic one-row source (no FROM) rather than a set-returning
  -- call, so the resolver values still surface even when zero operations
  -- match below (the 'ninguna' case) — LEFT JOIN against zero rows on the
  -- left would otherwise return zero rows overall, not one resolver-only row.
  FROM (SELECT v_resolver_resultado AS resultado, v_resolver_operation_id AS operation_id, v_resolver_candidatas AS candidatas) r
  LEFT JOIN ops o ON true
  LEFT JOIN remittance_beneficiaries b
         ON b.operation_id = o.id
        AND b.status = 'vigente'
  ORDER BY o.is_history ASC NULLS LAST, o.created_at DESC NULLS LAST, o.completed_at DESC NULLS LAST, b.position ASC NULLS LAST;
END $function$;

REVOKE ALL ON FUNCTION public.crm_operaciones_de_conversacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_operaciones_de_conversacion(uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
