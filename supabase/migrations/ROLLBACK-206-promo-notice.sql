-- ROLLBACK of 206_promo_notice.sql: restores cerebro_promo_registrar exactly as it was before 206
-- (production pg_get_functiondef md5 bd3c0b56e0173e32399dd73eadec1d7f on 2026-10-04; staging identical).
CREATE OR REPLACE FUNCTION public.cerebro_promo_registrar(p_min_cup numeric, p_max_cup numeric, p_multiplicador numeric, p_desde date, p_hasta date, p_titulo text, p_url text, p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_huella text;
  v_id uuid;
  v_precio numeric;
BEGIN
  -- La huella evita re-detectar la misma promo en cada pasada del cron.
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

  -- Aviso en el CRM a los tres usuarios. No depende de la ventana de 24 h
  -- de WhatsApp, que es justo lo que hoy falla.
  INSERT INTO notifications (account_id, user_id, type, title, body)
  SELECT '465fb4ce-33b6-4473-ad2c-42818772f587', u, 'promo_etecsa',
         'Nueva promocion de Etecsa detectada',
         format('%s-%s CUP x%s, del %s al %s. %s',
                p_min_cup, p_max_cup, p_multiplicador, p_desde, p_hasta,
                CASE WHEN v_precio IS NULL
                     THEN 'NO HAY PRECIO para ' || p_min_cup || ' CUP: hay que ponerlo antes de poder cotizar.'
                     ELSE 'Precio ' || v_precio || ' GYD. Confirmela para que el bot cotice solo.' END)
    FROM unnest(ARRAY['e3c7943d-b2fa-4c53-ae2f-406f1533ed47',
                      '5c4d16fd-1530-4023-8119-b58e04cc815f',
                      'ca797265-a1b3-43f7-9d9f-68c15d1f4780']::uuid[]) AS u;

  RETURN CASE WHEN v_precio IS NULL
              THEN 'detectada, PERO FALTA EL PRECIO para ' || p_min_cup || ' CUP'
              ELSE 'detectada, pendiente de confirmar' END;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] registrar promo fallo: %', SQLERRM;
  RETURN 'fallo: ' || SQLERRM;
END $function$;
