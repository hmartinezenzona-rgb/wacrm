-- 349: the Etecsa promo watcher no longer reports a failed read of etecsa.cu as a check.
--
-- Found 2026-10-28: since at least 2026-10-27 every run got ECONNREFUSED from etecsa.cu, yet
-- cerebro_promo_revision stamped promo_etecsa_ultima_revision and returned "revision hecha", so the
-- 29-31 Oct promo was never detected and nobody was told.
--
-- New optional payload key `leida` (the watcher sends it from now on):
--   leida = false -> promo_etecsa_ultima_revision is NOT touched; promo_etecsa_ultimo_fallo keeps the
--                    time and the error; the owner and admins of the business account get ONE notice
--                    per failure streak (none if one was sent after the last good read).
--   key absent    -> exactly the previous behaviour, so this can be applied before the n8n change.
-- Guard: CREATE OR REPLACE of one function, same signature and ACL; no table change (the notice reuses
-- type 'promo_etecsa', already allowed by notifications_type_check).
-- Rollback: ROLLBACK-349-promo-fallo-lectura.sql.

CREATE OR REPLACE FUNCTION public.cerebro_promo_revision(p_datos jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_res text;
  v_error text;
  v_account uuid;
  v_ultima timestamptz;
BEGIN
  -- A failed read of the site is not a check: the "last good check" mark must go stale so that it shows.
  IF p_datos ? 'leida' AND NOT coalesce((p_datos->>'leida')::boolean, false) THEN
    v_error := left(coalesce(nullif(p_datos->>'error', ''), 'sin detalle'), 300);

    INSERT INTO cerebro_config (clave, valor, descripcion)
    VALUES ('promo_etecsa_ultimo_fallo', now()::text || ' | ' || v_error,
            'Ultima vez que el vigilante de promociones NO pudo leer etecsa.cu, con el error (349).')
    ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, actualizado = now();

    SELECT valor::timestamptz INTO v_ultima
      FROM cerebro_config WHERE clave = 'promo_etecsa_ultima_revision';

    SELECT account_id INTO v_account FROM whatsapp_config LIMIT 1;

    -- One notice per failure streak: none if one was already sent after the last good read.
    IF NOT EXISTS (
      SELECT 1 FROM notifications n
       WHERE n.type = 'promo_etecsa'
         AND n.title = 'No se pudo revisar la web de Etecsa'
         AND n.created_at > coalesce(v_ultima, '-infinity'::timestamptz))
    THEN
      INSERT INTO notifications (account_id, user_id, type, title, body)
      SELECT v_account, p.user_id, 'promo_etecsa',
             'No se pudo revisar la web de Etecsa',
             format('El vigilante no pudo leer etecsa.cu (%s). Mientras siga asi no detecta promociones nuevas: '
                    || 'revise la web a mano. Ultima revision buena: %s.',
                    v_error,
                    coalesce(to_char(v_ultima AT TIME ZONE 'America/Guyana', 'YYYY-MM-DD HH24:MI'), 'nunca'))
        FROM profiles p
       WHERE p.account_id = v_account
         AND p.account_role IN ('owner', 'admin');
      RETURN 'fallo de lectura, avisado: ' || v_error;
    END IF;

    RETURN 'fallo de lectura, ya avisado: ' || v_error;
  END IF;

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
