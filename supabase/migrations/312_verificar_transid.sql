-- =====================================================================
-- 312 -- Verify a deposit from the TransID typed by the admin
--
-- Osmany verifies receipts forwarded as images, but he also sends the TransID written by hand (2026-10-24
-- 22:11, "10404033303182", got silence). This looks the deposit up in the MMG emails by TransID, applies the
-- same rules as the receipt cross (anulado, ya reclamado, antigüedad) and, when it is free, CONSUMES it with
-- operation_id NULL — the admin verification creates no operation (310/311). The amount and holder come from
-- the MMG record, so nothing is invented.
-- Assertion: supabase/staging/assertions/verificar-transid.sql. Rollback: ROLLBACK-312-verificar-transid.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_verificar_transid(p_ref text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ref text := NULLIF(regexp_replace(COALESCE(p_ref, ''), '[^0-9]', '', 'g'), '');
  v_max integer := COALESCE(NULLIF(cerebro_config_get('cruce_antiguedad_max_horas'), '')::int, 72);
  d record;
  v_tocado integer;
BEGIN
  IF v_ref IS NULL THEN
    RETURN 'SIN CRUCE (sin_referencia): no leí un TransID.';
  END IF;

  SELECT * INTO d
    FROM depositos_mmg x
   WHERE x.trans_id = v_ref
   ORDER BY x.recibido_en DESC
   LIMIT 1
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN 'SIN CRUCE (sin_correo): no hay ningun deposito con el TransID ' || v_ref || '.';
  END IF;
  IF d.anulado_en IS NOT NULL THEN
    RETURN 'DEPOSITO ANULADO: el TransID ' || v_ref || ' esta anulado; no cuenta.';
  END IF;
  IF d.consumido_en IS NOT NULL THEN
    RETURN 'YA RECLAMADO: el TransID ' || v_ref || ' ya se uso.'
        || chr(10) || 'Importe: ' || d.monto || ' ' || COALESCE(d.moneda, 'GYD') || '.';
  END IF;
  IF d.recibido_en < now() - make_interval(hours => v_max) THEN
    RETURN 'DEPOSITO ANTIGUO: mas de ' || v_max || ' horas. NO se consumio; hay que mirarlo a mano.'
        || chr(10) || 'Importe: ' || d.monto || ' ' || COALESCE(d.moneda, 'GYD') || '.';
  END IF;

  UPDATE depositos_mmg
     SET consumido_en = now()
   WHERE trans_id = d.trans_id AND consumido_en IS NULL;
  GET DIAGNOSTICS v_tocado = ROW_COUNT;
  IF v_tocado = 0 THEN
    RETURN 'YA RECLAMADO: el TransID ' || v_ref || ' se uso en este instante.';
  END IF;

  RETURN 'VERIFICADO: el TransID ' || v_ref || ' esta en el correo de MMG.'
      || chr(10) || 'Importe: ' || d.monto || ' ' || COALESCE(d.moneda, 'GYD')
      || chr(10) || COALESCE('Titular: ' || NULLIF(d.titular, '') || chr(10), '')
      || 'Metodo: transid escrito'
      || chr(10) || 'El deposito queda consumido.';
END;
$function$;

COMMENT ON FUNCTION public.cerebro_verificar_transid(text) IS
  'Admin verification from a written TransID: looks the deposit up in depositos_mmg, applies the same rules as '
  'the receipt cross and consumes it with operation_id NULL (312).';

REVOKE ALL ON FUNCTION public.cerebro_verificar_transid(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_verificar_transid(text) TO service_role;
