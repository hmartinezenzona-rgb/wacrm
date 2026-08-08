-- ============================================================
--  AVISO EN EL CRM CUANDO UN DEAL CAE EN INCIDENCIA
--  Aplicado en produccion el 2026-08-08.
--  Va en el repo de WaCRM como supabase/migrations/038_*.sql,
--  junto al 037_cerebro_schema.sql.
-- ============================================================
--
--  Hasta ahora, cuando un envio caia en Incidencia solo salia un mensaje de
--  WhatsApp al admin. Ese mensaje depende de la ventana de 24 h de WhatsApp y
--  se apaga solo en silencio (ver PENDIENTES.md). Con esto, ademas, entra un
--  aviso en el propio CRM, que es donde el equipo ya esta trabajando.
--
--  Se apoya entero en lo que ya existia: la tabla `notifications`, su realtime,
--  su politica por usuario y el badge de la barra lateral. Lo unico que faltaba
--  era que algo escribiera la fila.
--
--  OJO - LA TRAMPA DE ESTA BASE DE DATOS
--  `profiles` tiene DOS columnas de identidad:
--      profiles.id       -> clave propia de la tabla
--      profiles.user_id  -> el usuario de autenticacion (auth.users.id)
--  `notifications.user_id` apunta a auth.users, asi que hay que usar
--  `profiles.user_id`. Usar `profiles.id` viola la clave ajena, y como el
--  disparador se traga los errores a proposito, falla EN SILENCIO.
-- ============================================================

-- El CHECK solo admitia 'conversation_assigned'.
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN ('conversation_assigned', 'deal_incidencia'));

CREATE OR REPLACE FUNCTION public.notify_deal_incidencia()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  INCIDENCIA constant uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_cuerpo text;
BEGIN
  -- Solo cuando ENTRA en Incidencia. En UPDATE, solo si venia de otra etapa,
  -- para no repetir el aviso cada vez que se edita el deal.
  IF NEW.stage_id IS DISTINCT FROM INCIDENCIA THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.stage_id IS NOT DISTINCT FROM INCIDENCIA THEN
    RETURN NEW;
  END IF;

  -- La ultima linea de las notas es el motivo que escribio el cruce.
  v_cuerpo := NULLIF(trim(split_part(COALESCE(NEW.notes,''), chr(10),
                array_length(string_to_array(COALESCE(NEW.notes,''), chr(10)), 1))), '');

  INSERT INTO notifications (account_id, user_id, type, conversation_id,
                             contact_id, actor_user_id, title, body)
  SELECT NEW.account_id, p.user_id, 'deal_incidencia', NEW.conversation_id,
         NEW.contact_id, NULL,
         'Incidencia: ' || COALESCE(NEW.title, 'remesa') || ' - ' ||
           to_char(COALESCE(NEW.value,0), 'FM999,999,999') || ' ' ||
           COALESCE(NEW.currency, 'GYD'),
         COALESCE(v_cuerpo, 'Un envio necesita revision manual.')
    FROM profiles p
   WHERE p.account_id = NEW.account_id
     AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.user_id);

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Un aviso que no sale es molesto; un deal que no se guarda porque fallo el
  -- aviso seria grave. El error NUNCA se propaga al flujo del dinero.
  RAISE WARNING 'notify_deal_incidencia fallo para el deal %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_notify_deal_incidencia ON deals;
CREATE TRIGGER trg_notify_deal_incidencia
  AFTER INSERT OR UPDATE OF stage_id ON deals
  FOR EACH ROW EXECUTE FUNCTION public.notify_deal_incidencia();

-- ============================================================
--  PROBADO ASI (no deja rastro: el RAISE revierte la transaccion entera)
--
--  DO $$
--  DECLARE v_deal uuid; v_n int; v_users text;
--  BEGIN
--    SELECT id INTO v_deal FROM deals
--     WHERE pipeline_id='78220927-0745-45a8-ba08-a1b33734dbf1'
--       AND stage_id <> 'da7b3e24-9222-4150-8be8-d7f7378e16aa'
--     ORDER BY created_at DESC LIMIT 1;
--    UPDATE deals SET stage_id='da7b3e24-9222-4150-8be8-d7f7378e16aa' WHERE id=v_deal;
--    SELECT count(*), string_agg(p.full_name, ', ') INTO v_n, v_users
--      FROM notifications n JOIN profiles p ON p.user_id=n.user_id
--     WHERE n.type='deal_incidencia';
--    RAISE EXCEPTION 'avisos: % a %', v_n, v_users;
--  END $$;
--
--  Resultado: 3 avisos, a Admin, eliaba y osmany.
--
--  REVERSION
--    DROP TRIGGER IF EXISTS trg_notify_deal_incidencia ON deals;
--    DROP FUNCTION IF EXISTS public.notify_deal_incidencia();
--    -- y dejar el CHECK como estaba si se quiere:
--    -- ALTER TABLE notifications DROP CONSTRAINT notifications_type_check;
--    -- ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
--    --   CHECK (type IN ('conversation_assigned'));
-- ============================================================
