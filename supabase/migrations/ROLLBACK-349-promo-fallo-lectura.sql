-- Rollback of 349: restores cerebro_promo_revision as read from production with pg_get_functiondef on
-- 2026-10-28 (every call stamps promo_etecsa_ultima_revision, even when the read failed).
-- The config row promo_etecsa_ultimo_fallo and any failure notices are left in place (harmless data).

CREATE OR REPLACE FUNCTION public.cerebro_promo_revision(p_datos jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_res text;
BEGIN
  -- Deja constancia de que el vigilante pasó por aquí, encuentre o no
  -- promocion. Si esta marca se queda vieja, el scraper esta muerto —
  -- y eso hay que poder verlo.
  INSERT INTO cerebro_config (clave, valor, descripcion)
  VALUES ('promo_etecsa_ultima_revision', now()::text,
          'Ultima vez que el vigilante de promociones leyo etecsa.cu con exito. Si lleva mas de 2 dias sin moverse, el scraper esta roto.')
  ON CONFLICT (clave) DO UPDATE SET valor = now()::text, actualizado = now();

  IF coalesce((p_datos->>'ok')::boolean, false) THEN
    SELECT cerebro_promo_registrar(
      (p_datos->>'min_cup')::numeric,
      (p_datos->>'max_cup')::numeric,
      (p_datos->>'multiplicador')::numeric,
      (p_datos->>'desde')::date,
      (p_datos->>'hasta')::date,
      p_datos->>'titulo',
      p_datos->>'url',
      p_datos->>'texto') INTO v_res;
    RETURN v_res;
  END IF;

  RETURN 'revision hecha, sin promocion legible';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] revision de promo fallo: %', SQLERRM;
  RETURN 'fallo: ' || SQLERRM;
END $function$;
