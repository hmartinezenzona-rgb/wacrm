-- ROLLBACK of 334: restores funding_caso_panel exactly as in 332 and drops the two action RPCs.
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
       WHERE a.case_id = v_case.id), '[]'::jsonb)
  ));
END $function$;;

DROP FUNCTION IF EXISTS public.funding_caso_asignar_panel(uuid, uuid, numeric, text);
DROP FUNCTION IF EXISTS public.funding_caso_liberar_panel(uuid, text, text);
