-- =====================================================================
-- 334 -- Panel actions: assign and release GYD of the funding case
--
-- The panel could see the case but not act. This migration:
--   * adds the open operations (service, status, quoted amount and committed allocation) to
--     funding_caso_panel, so the operator can choose where to assign;
--   * adds funding_caso_asignar_panel (agent): calls funding_asignar with operator evidence;
--   * adds funding_caso_liberar_panel (agent): calls funding_liberar.
-- Both check is_account_member themselves. Refunds are not included: they need an owner rule for
-- fees and the source deposit before money can leave a case.
--
-- Assertion: supabase/staging/assertions/funding-caso-acciones.sql.
-- Rollback: ROLLBACK-334-funding-caso-acciones.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.funding_caso_panel(p_conversation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_case    funding_case%ROWTYPE;
  v_dep     numeric;
  v_asig    numeric;
  v_disp    numeric;
BEGIN
  IF p_conversation IS NULL THEN
    RAISE EXCEPTION 'conversation is required' USING ERRCODE = '22023';
  END IF;

  SELECT c.account_id INTO v_account FROM conversations c WHERE c.id = p_conversation;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'conversation not found' USING ERRCODE = 'P0002';
  END IF;
  IF auth.uid() IS NULL OR NOT is_account_member(v_account, 'viewer'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to read this funding case' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_case
    FROM funding_case fc
   WHERE fc.conversation_id = p_conversation AND fc.status <> 'closed'
   ORDER BY fc.opened_at DESC
   LIMIT 1;
  IF NOT FOUND THEN
    SELECT * INTO v_case
      FROM funding_case fc
     WHERE fc.conversation_id = p_conversation
     ORDER BY fc.opened_at DESC
     LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('case', NULL);
    END IF;
  END IF;

  SELECT s.depositado, s.asignado, s.disponible
    INTO v_dep, v_asig, v_disp
    FROM funding_case_saldo(v_case.id) s;

  RETURN jsonb_build_object('case', jsonb_build_object(
    'id', v_case.id,
    'status', v_case.status,
    'opened_at', v_case.opened_at,
    'closed_at', v_case.closed_at,
    'note', v_case.note,
    'depositado', v_dep,
    'asignado', v_asig,
    'disponible', v_disp,
    'deposits', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'trans_id', d.trans_id,
               'monto', d.monto,
               'recibido_en', d.recibido_en,
               'anulado_en', d.anulado_en)
             ORDER BY d.recibido_en DESC)
        FROM case_deposits cd
        JOIN depositos_mmg d ON d.trans_id = cd.deposit_trans_id
       WHERE cd.case_id = v_case.id), '[]'::jsonb),
    'allocations', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'operation_id', a.operation_id,
               'service', cerebro_riel_op(a.operation_id),
               'amount_gyd', a.amount_gyd,
               'status', a.status,
               'evidence_type', a.evidence_type,
               'created_at', a.created_at)
             ORDER BY a.created_at)
        FROM funding_allocations a
       WHERE a.case_id = v_case.id), '[]'::jsonb),
    'operations', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', o.id,
               'service', cerebro_riel_op(o.id),
               'status', o.status,
               'quoted_source_amount', o.quoted_source_amount,
               'allocated', COALESCE((
                 SELECT sum(x.amount_gyd) FROM funding_allocations x
                  WHERE x.operation_id = o.id AND x.status = 'committed'), 0))
             ORDER BY o.created_at, o.id)
        FROM remittance_operations o
       WHERE o.conversation_id = p_conversation
         AND o.status NOT IN ('completed', 'cancelled')
         AND (o.case_id IS NULL OR o.case_id = v_case.id)), '[]'::jsonb)
  ));
END $function$;;

CREATE OR REPLACE FUNCTION public.funding_caso_asignar_panel(
  p_case uuid,
  p_operation_id uuid,
  p_amount_gyd numeric,
  p_idempotency_key text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_conv    uuid;
BEGIN
  IF p_case IS NULL OR p_operation_id IS NULL OR p_amount_gyd IS NULL OR p_amount_gyd <= 0 THEN
    RAISE EXCEPTION 'case, operation and a positive amount are required' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'an idempotency key is required' USING ERRCODE = '22023';
  END IF;

  SELECT fc.account_id, fc.conversation_id INTO v_account, v_conv
    FROM funding_case fc WHERE fc.id = p_case;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'funding case not found' USING ERRCODE = 'P0002';
  END IF;
  IF auth.uid() IS NULL OR NOT is_account_member(v_account, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to assign this funding case' USING ERRCODE = '42501';
  END IF;

  PERFORM funding_asignar(p_case, p_operation_id, p_amount_gyd, 'operator',
                          p_idempotency_key, 'panel:' || auth.uid()::text);
  RETURN funding_caso_panel(v_conv);
END $function$;

COMMENT ON FUNCTION public.funding_caso_asignar_panel(uuid, uuid, numeric, text) IS
  '334: the panel assigns GYD of the case to an open operation (operator evidence). SECURITY DEFINER; '
  'requires the agent role; funding_asignar enforces the balance and the operation.';

CREATE OR REPLACE FUNCTION public.funding_caso_liberar_panel(
  p_allocation_id uuid,
  p_idempotency_key text,
  p_reason text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_conv    uuid;
BEGIN
  IF p_allocation_id IS NULL OR NULLIF(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'allocation and idempotency key are required' USING ERRCODE = '22023';
  END IF;

  SELECT fc.account_id, fc.conversation_id INTO v_account, v_conv
    FROM funding_allocations a
    JOIN funding_case fc ON fc.id = a.case_id
   WHERE a.id = p_allocation_id;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'allocation not found' USING ERRCODE = 'P0002';
  END IF;
  IF auth.uid() IS NULL OR NOT is_account_member(v_account, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to release this allocation' USING ERRCODE = '42501';
  END IF;

  PERFORM funding_liberar(p_allocation_id, p_idempotency_key, p_reason, 'panel:' || auth.uid()::text);
  RETURN funding_caso_panel(v_conv);
END $function$;

COMMENT ON FUNCTION public.funding_caso_liberar_panel(uuid, text, text) IS
  '334: the panel releases a committed allocation. SECURITY DEFINER; requires the agent role; '
  'funding_liberar refuses the allocation of a completed operation.';

REVOKE ALL ON FUNCTION public.funding_caso_asignar_panel(uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_caso_liberar_panel(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.funding_caso_asignar_panel(uuid, uuid, numeric, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.funding_caso_liberar_panel(uuid, text, text) TO authenticated, service_role;
