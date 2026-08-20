-- =====================================================================
-- 090 — Incidencias legibles para los administradores
--
-- Aplicada en producción el 2026-08-20 (Supabase migration 20260820034714).
-- No volver a ejecutarla manualmente.
--
-- La incidencia ya llegaba al CRM, pero el aviso solo identificaba el deal
-- y el motivo quedaba como un párrafo difícil de leer. El nombre se toma de
-- contacts.name, que WaCRM rellena con el perfil de WhatsApp cuando Meta lo
-- entrega; el teléfono queda como identificador estable de respaldo.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.notify_deal_incidencia()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  INCIDENCIA constant uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_motivo text;
  v_nombre text;
  v_telefono text;
  v_cliente text;
BEGIN
  -- Solo cuando entra en Incidencia; editar un deal ya incidente no repite
  -- la alerta ni llena de ruido la bandeja de los administradores.
  IF NEW.stage_id IS DISTINCT FROM INCIDENCIA THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.stage_id IS NOT DISTINCT FROM INCIDENCIA THEN
    RETURN NEW;
  END IF;

  SELECT NULLIF(btrim(c.name), ''), NULLIF(btrim(c.phone), '')
    INTO v_nombre, v_telefono
    FROM contacts c
   WHERE c.id = NEW.contact_id;

  v_cliente := COALESCE(v_nombre, 'Cliente sin nombre');
  v_motivo := NULLIF(trim(split_part(COALESCE(NEW.notes, ''), chr(10),
                array_length(string_to_array(COALESCE(NEW.notes, ''), chr(10)), 1))), '');

  INSERT INTO notifications (
    account_id, user_id, type, conversation_id, contact_id,
    actor_user_id, title, body
  )
  SELECT NEW.account_id,
         p.user_id,
         'deal_incidencia',
         NEW.conversation_id,
         NEW.contact_id,
         NULL,
         'INCIDENCIA | ' || v_cliente || ' | WhatsApp ' || COALESCE(v_telefono, 'sin número'),
         'CLIENTE: ' || v_cliente || chr(10)
         || 'WHATSAPP: ' || COALESCE(v_telefono, 'sin número') || chr(10)
         || 'ENVÍO: ' || COALESCE(NEW.title, 'remesa') || chr(10)
         || 'MONTO: ' || to_char(COALESCE(NEW.value, 0), 'FM999,999,999') || ' '
                       || COALESCE(NEW.currency, 'GYD') || chr(10)
         || 'MOTIVO:' || chr(10)
         || COALESCE(v_motivo, 'Un envío necesita revisión manual.')
    FROM profiles p
   WHERE p.account_id = NEW.account_id
     AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.user_id);

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- La alerta nunca debe impedir guardar el movimiento financiero.
  RAISE WARNING 'notify_deal_incidencia fallo para el deal %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.notify_deal_incidencia() IS
  'Crea una alerta legible con nombre WhatsApp, teléfono, envío, monto y motivo.';
