-- 370 -- The operations panel reads the conversation's planned split.
--
-- A split planned before the deposit (cerebro_reparto_planeado, 277) is not grouped yet (369 gives each part its agreed amount, the group forms when
-- a deposit of exactly the total arrives). The panel shows those operations as ONE mixed send waiting for the deposit, so it needs the plan: one row
-- per part in the customer's order (servicio, monto_gyd, posicion) with the plan total. The table stays service_role only; this function changes
-- nothing. Authorization as crm_cotizacion_de_conversacion (187): viewer of the conversation's account, 42501 otherwise.
-- Guarded by supabase/staging/assertions/planned-split-panel-read.sql. Rollback: ROLLBACK-370-planned-split-panel-read.sql.

CREATE OR REPLACE FUNCTION public.crm_reparto_planeado_de_conversacion(p_conversation_id uuid)
RETURNS TABLE(servicio text, monto_gyd numeric, posicion integer, total_gyd numeric)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id uuid;
BEGIN
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;
  SELECT c.account_id INTO v_account_id FROM conversations c WHERE c.id = p_conversation_id;
  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT e ->> 'servicio', (e ->> 'monto_gyd')::numeric, t.ord::integer, pl.total_gyd
    FROM cerebro_reparto_planeado pl
    CROSS JOIN LATERAL jsonb_array_elements(pl.partes) WITH ORDINALITY t(e, ord)
   WHERE pl.conversation_id = p_conversation_id
   ORDER BY t.ord;
END $$;

REVOKE ALL ON FUNCTION public.crm_reparto_planeado_de_conversacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_reparto_planeado_de_conversacion(uuid) TO authenticated, service_role;
