-- ============================================================
--  VIGILANTE DE MENSAJES QUE WHATSAPP RECHAZO
--  Aplicado en produccion el 2026-08-08.
-- ============================================================
--
--  EL PROBLEMA
--  WhatsApp solo deja mandar texto libre durante las 24 h siguientes al
--  ultimo mensaje del destinatario. Pasado ese plazo el mensaje se rechaza
--  y queda con status='failed'. **Nadie se entera**: no hay reintento, no
--  hay aviso, y el unico rastro es una fila que no mira nadie.
--
--  Asi se perdieron 41 avisos a los tres numeros de admin entre el 7 y el
--  8 de agosto -derivaciones, incidencias y fallos del Cerebro- sin que
--  nadie lo notara. A clientes todavia no ha fallado ninguno, pero el
--  record medido son 16,1 h entre el ultimo mensaje del cliente y un
--  "su remesa fue completada": quedan 8 h de margen.
--
--  POR QUE UN CRON Y NO UN DISPARADOR
--  Lo natural seria un trigger en `messages`, pero esa es la tabla mas
--  caliente del sistema: cada mensaje que entra y cada respuesta que sale
--  pasa por ahi, y es el camino por el que el Cerebro se entera de que hay
--  un cliente escribiendo. Meter codigo en ese carril para algo que no es
--  urgente es mal negocio. Un cron cada 5 minutos consigue lo mismo sin
--  tocar el camino critico: si el cron se cae, lo unico que se pierde es
--  el aviso, que es justo donde estabamos antes.
--
--  POR QUE NO AVISA POR WHATSAPP
--  Porque se realimentaria. Un aviso de "un mensaje fallo" que a su vez
--  falla queda registrado como otro mensaje fallido, del que avisaria la
--  siguiente pasada, y asi indefinidamente. El aviso va al CRM, que no
--  depende de la ventana de 24 h.
-- ============================================================

-- Registro de que mensajes ya se avisaron. No toca `messages` ni su camino.
CREATE TABLE IF NOT EXISTS cerebro_alertas_enviadas (
  message_id uuid PRIMARY KEY,
  avisado_en timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON cerebro_alertas_enviadas FROM PUBLIC;
ALTER TABLE cerebro_alertas_enviadas ENABLE ROW LEVEL SECURITY;

-- Se siembra con TODOS los fallos que ya existian para que la primera pasada
-- no dispare un aviso por 41 mensajes viejos que ya conocemos.
INSERT INTO cerebro_alertas_enviadas (message_id)
SELECT id FROM messages WHERE status = 'failed'
ON CONFLICT DO NOTHING;

-- Tipo nuevo de aviso en el CRM.
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN ('conversation_assigned', 'deal_incidencia', 'mensaje_fallido'));

CREATE OR REPLACE FUNCTION public.cerebro_avisar_mensajes_fallidos(p_horas int DEFAULT 6)
RETURNS TABLE (mensajes_nuevos int, avisos_creados int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_n       int := 0;
  v_avisos  int := 0;
  v_cuenta  uuid;
  v_detalle text;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _fallidos (
    id uuid, account_id uuid, phone text, created_at timestamptz, content_text text
  ) ON COMMIT DROP;
  DELETE FROM _fallidos;

  INSERT INTO _fallidos
  SELECT m.id, v.account_id, c.phone, m.created_at, m.content_text
    FROM messages m
    JOIN conversations v ON v.id = m.conversation_id
    JOIN contacts c      ON c.id = v.contact_id
   WHERE m.status = 'failed'
     AND m.created_at > now() - make_interval(hours => p_horas)
     AND NOT EXISTS (SELECT 1 FROM cerebro_alertas_enviadas a WHERE a.message_id = m.id);

  SELECT count(*) INTO v_n FROM _fallidos;
  IF v_n = 0 THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  -- Un aviso por cuenta afectada, resumiendo. Si entran 30 fallos de golpe se
  -- avisa una vez de los 30, no treinta veces.
  FOR v_cuenta IN SELECT DISTINCT account_id FROM _fallidos WHERE account_id IS NOT NULL LOOP
    SELECT string_agg(DISTINCT phone, ', ') INTO v_detalle
      FROM _fallidos WHERE account_id = v_cuenta;

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT v_cuenta, p.user_id, 'mensaje_fallido',
           'WhatsApp rechazo ' || (SELECT count(*) FROM _fallidos WHERE account_id = v_cuenta)
             || ' mensaje(s)',
           'No llegaron a: ' || COALESCE(v_detalle, '?')
             || '. Casi siempre es la ventana de 24 h de WhatsApp: solo se puede'
             || ' escribir texto libre durante las 24 h siguientes al ultimo'
             || ' mensaje de esa persona. Revise si hay que contactarla por otra via.'
      FROM profiles p
     WHERE p.account_id = v_cuenta
       AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.user_id);

    GET DIAGNOSTICS v_avisos = ROW_COUNT;
  END LOOP;

  INSERT INTO cerebro_alertas_enviadas (message_id)
  SELECT id FROM _fallidos ON CONFLICT DO NOTHING;

  RETURN QUERY SELECT v_n, v_avisos;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.cerebro_avisar_mensajes_fallidos(int) TO PUBLIC;

-- ============================================================
--  QUIEN LO LLAMA
--  Workflow de n8n `Vigilante - mensajes que WhatsApp rechazo`
--  (rNN0LdHGTYUDOTfB), cada 5 minutos. Un solo nodo Postgres:
--      SELECT * FROM cerebro_avisar_mensajes_fallidos(6);
--
--  PROBADO ASI (no deja rastro: el RAISE revierte la transaccion entera)
--    DO $$
--    DECLARE r record; v_msg uuid;
--    BEGIN
--      INSERT INTO messages (conversation_id, sender_type, content_type,
--                            content_text, status)
--      VALUES ('40e6ab76-9597-4a2b-bf18-96450476a8bb','agent','text',
--              'PRUEBA fallo','failed') RETURNING id INTO v_msg;
--      SELECT * INTO r FROM cerebro_avisar_mensajes_fallidos(6);
--      RAISE EXCEPTION 'detectados: %  avisos: %', r.mensajes_nuevos, r.avisos_creados;
--    END $$;
--
--  Resultado: 1 detectado, 3 avisos (Admin, eliaba, osmany).
--
--  REVERSION
--    Desactivar el workflow en n8n. Sin nadie que la llame, la funcion no
--    hace nada. Para borrarlo del todo:
--      DROP FUNCTION IF EXISTS public.cerebro_avisar_mensajes_fallidos(int);
--      DROP TABLE IF EXISTS cerebro_alertas_enviadas;
--
--  REVISION
--    SELECT * FROM notifications WHERE type='mensaje_fallido'
--     ORDER BY created_at DESC;
-- ============================================================
