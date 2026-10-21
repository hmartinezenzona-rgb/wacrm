-- =====================================================================
-- 258 -- The operations board says what each operation is (staging first)
--
-- odd/tasks/tablero-informativo.md (T1). crm_tablero_operaciones() also returns, per operation:
--   beneficiary_types        types of the vigente beneficiaries, ordered by block_index, position ('{}' when none)
--   quoted_destination_amount / destination_currency   what the recipient gets
--   recipient_label          first vigente beneficiary (block_index, position): its name; else 'Tarjeta ·' || last 4 of the
--                            card; else the Zelle account; else the phone; NULL when none. Card numbers only as last 4.
--   recipient_count          vigente beneficiaries (the UI shows "+N")
--   mixed_group_id           the mixed-send group of the operation (253), NULL otherwise
-- The return type changes, so the function is dropped and created again. Body, authorization, filters and ordering are
-- those of the live staging function (which already includes the 'awaiting_deposit'/'deposit_received' statuses).
-- Grants as 219: authenticated only.
-- =====================================================================
DROP FUNCTION IF EXISTS public.crm_tablero_operaciones();

CREATE FUNCTION public.crm_tablero_operaciones()
 RETURNS TABLE(operation_id uuid, conversation_id uuid, contact_name text, contact_phone text, service_type text, delivery_method text, status text, quoted_source_amount numeric, source_currency text, created_at timestamp with time zone, completed_at timestamp with time zone, state_since timestamp with time zone, beneficiaries_complete boolean, beneficiary_types text[], quoted_destination_amount numeric, destination_currency text, recipient_label text, recipient_count integer, mixed_group_id uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  SELECT p.account_id INTO v_account_id
    FROM profiles p
   WHERE p.user_id = auth.uid()
   LIMIT 1;

  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    b.id,
    b.conversation_id,
    c.name,
    c.phone,
    b.service_type,
    b.delivery_method,
    b.status,
    b.quoted_source_amount,
    b.source_currency,
    b.created_at,
    b.completed_at,
    b.since,
    crm_beneficiarios_completos(b.id),
    bn.types,
    b.quoted_destination_amount,
    b.destination_currency,
    bn.label,
    bn.n,
    b.mixed_group_id
  FROM (
    SELECT o.*,
           CASE
             WHEN o.status = 'completed' THEN coalesce(o.completed_at, o.status_changed_at, o.updated_at)
             ELSE coalesce(
               o.status_changed_at,
               (SELECT max(a.created_at)
                  FROM remittance_admin_audit a
                 WHERE a.table_name = 'remittance_operations'
                   AND a.row_id = o.id
                   AND a.field_name = 'status'
                   AND a.after ->> 'status' = o.status),
               o.updated_at)
           END AS since,
           CASE o.status
             WHEN 'collecting_information' THEN 1
             WHEN 'awaiting_deposit'       THEN 1
             WHEN 'deposit_verification'   THEN 2
             WHEN 'deposit_received'       THEN 2
             WHEN 'ready_to_transfer'      THEN 3
             WHEN 'transferring'           THEN 3
             WHEN 'incident'               THEN 4
             ELSE 5
           END AS col_rank
      FROM remittance_operations o
     WHERE o.account_id = v_account_id
       AND (o.status IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer', 'transferring', 'incident')
            OR (o.status = 'completed' AND o.completed_at >= now() - interval '24 hours'))
  ) b
  LEFT JOIN conversations cv ON cv.id = b.conversation_id
  LEFT JOIN contacts c ON c.id = coalesce(b.contact_id, cv.contact_id)
  CROSS JOIN LATERAL (
    SELECT coalesce(array_agg(x.beneficiary_type ORDER BY x.block_index, x.position), ARRAY[]::text[]) AS types,
           (array_agg(
              CASE
                WHEN btrim(coalesce(x.name, '')) <> '' THEN btrim(x.name)
                WHEN btrim(coalesce(x.card_number, '')) <> '' THEN 'Tarjeta ·' || right(btrim(x.card_number), 4)
                WHEN btrim(coalesce(x.zelle_account, '')) <> '' THEN btrim(x.zelle_account)
                WHEN btrim(coalesce(x.phone, '')) <> '' THEN btrim(x.phone)
              END
              ORDER BY x.block_index, x.position))[1] AS label,
           count(*)::integer AS n
      FROM remittance_beneficiaries x
     WHERE x.operation_id = b.id AND x.status = 'vigente'
  ) bn
  ORDER BY b.col_rank, b.since;
END $function$;

REVOKE ALL ON FUNCTION public.crm_tablero_operaciones() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_tablero_operaciones() TO authenticated;
