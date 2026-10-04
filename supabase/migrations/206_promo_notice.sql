-- =====================================================================
-- 206 — The ETECSA promo notice reaches the business admins, and an ended promo is ignored
--
-- Owner, 2026-10-04: the monitor's notice "never arrives" and there is nothing to confirm.
--   * cerebro_promo_registrar hard-coded production's account and three user ids: on staging the notice failed
--     (FK on notifications.account_id) and a new admin in production would never get it. The recipients are now
--     the owner and admins of the business account, the account of whatsapp_config.
--   * A promo that has already ended (hasta before today, Guyana time) is neither registered nor notified: the
--     27–31 Jul promo was notified on 2026-08-20.
-- Everything else (fingerprint, price check, texts, return values) is unchanged.
-- Assertion: supabase/staging/assertions/promo-notice.sql. Rollback: ROLLBACK-206-promo-notice.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_promo_registrar(
  p_min_cup numeric, p_max_cup numeric, p_multiplicador numeric,
  p_desde date, p_hasta date, p_titulo text, p_url text, p_texto text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_huella text;
  v_id uuid;
  v_precio numeric;
  v_account uuid;
BEGIN
  -- An ended promo is history: registering it would only raise a notice nobody can act on.
  IF p_hasta < (now() AT TIME ZONE 'America/Guyana')::date THEN
    RETURN 'ya terminada, no se avisa';
  END IF;

  -- The fingerprint keeps each cron pass from detecting the same promo again.
  v_huella := md5(concat_ws('|', p_min_cup, p_max_cup, p_multiplicador, p_desde, p_hasta));

  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde,
                            vigente_hasta, titulo, url, texto_crudo, huella)
  VALUES (p_min_cup, p_max_cup, p_multiplicador, p_desde, p_hasta,
          p_titulo, p_url, left(p_texto, 4000), v_huella)
  ON CONFLICT (huella) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN 'ya conocida, sin cambios';
  END IF;

  SELECT precio_gyd INTO v_precio FROM precio_recarga WHERE min_cup = p_min_cup;

  -- Notice in the CRM (not tied to WhatsApp's 24 h window) for the business owner and admins.
  SELECT account_id INTO v_account FROM whatsapp_config LIMIT 1;
  INSERT INTO notifications (account_id, user_id, type, title, body)
  SELECT v_account, p.user_id, 'promo_etecsa',
         'Nueva promocion de Etecsa detectada',
         format('%s-%s CUP x%s, del %s al %s. %s',
                p_min_cup, p_max_cup, p_multiplicador, p_desde, p_hasta,
                CASE WHEN v_precio IS NULL
                     THEN 'NO HAY PRECIO para ' || p_min_cup || ' CUP: hay que ponerlo antes de poder cotizar.'
                     ELSE 'Precio ' || v_precio || ' GYD. Confirmela para que el bot cotice solo.' END)
    FROM profiles p
   WHERE p.account_id = v_account
     AND p.account_role IN ('owner', 'admin');

  RETURN CASE WHEN v_precio IS NULL
              THEN 'detectada, PERO FALTA EL PRECIO para ' || p_min_cup || ' CUP'
              ELSE 'detectada, pendiente de confirmar' END;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] registrar promo fallo: %', SQLERRM;
  RETURN 'fallo: ' || SQLERRM;
END $$;
