-- =====================================================================
-- 310 -- Admin receipt verification must not create an operation
--
-- Every forwarded receipt went through cerebro_registrar_deposito before the Decisor knew the sender was the
-- admin, so validating a deposit created a deal + operation that stayed "waiting for beneficiary" forever (two
-- real cases on 2026-10-24: 5,000 and 25,000 GYD). This wrapper keeps the client path untouched and, for a
-- conversation whose contact carries the `admin` tag, creates nothing: it returns a NULL deal id so the MMG
-- cross validates and consumes the deposit with no operation attached.
-- Assertion: supabase/staging/assertions/registrar-deposito-admin.sql.
-- Rollback: ROLLBACK-310-registrar-deposito-admin.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito_si_cliente(
  p_conv uuid,
  p_monto numeric,
  p_moneda text,
  p_stage uuid,
  p_nota text,
  p_comp_id text
)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM public.conversations v
      JOIN public.contacts c ON c.id = v.contact_id
      JOIN public.contact_tags ct ON ct.contact_id = c.id
      JOIN public.tags t ON t.id = ct.tag_id
     WHERE v.id = p_conv
       AND lower(t.name) = 'admin'
  ) THEN
    -- Verification only: the cross reads the receipt and consumes the deposit, with no deal behind it.
    RETURN QUERY SELECT NULL::uuid, 'verificacion_admin'::text, false, false;
    RETURN;
  END IF;

  RETURN QUERY
    SELECT * FROM public.cerebro_registrar_deposito(p_conv, p_monto, p_moneda, p_stage, p_nota, p_comp_id);
END;
$function$;

COMMENT ON FUNCTION public.cerebro_registrar_deposito_si_cliente(uuid, numeric, text, uuid, text, text) IS
  'Same as cerebro_registrar_deposito for customers; for an admin-tagged conversation it creates nothing and '
  'returns a NULL deal id, so the receipt is only verified and the deposit consumed (310).';

REVOKE ALL ON FUNCTION public.cerebro_registrar_deposito_si_cliente(uuid, numeric, text, uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_deposito_si_cliente(uuid, numeric, text, uuid, text, text)
  TO service_role;
