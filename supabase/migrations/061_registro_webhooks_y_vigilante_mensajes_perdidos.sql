-- 061 — Registro de webhooks de WhatsApp y vigilante de mensajes perdidos
-- YA APLICADA EN PRODUCCION el 10-ago-2026. NO LA EJECUTES.
--
-- POR QUE
-- El 10-ago un cliente (592 6731279) escribio cinco veces con doble tick y
-- NINGUNO de sus mensajes llego al CRM. No habia forma de saberlo: WaCRM no
-- guardaba nada de lo que Meta le entregaba, asi que un mensaje que fallaba al
-- insertarse desaparecia sin dejar rastro.
-- Ver docs/negocio/GUIA-HERMES-webhook-tira-mensajes.md
--
-- REPARTO
--   Esta migracion (Claude): la tabla, sus indices y el vigilante.
--   WaCRM (Hermes): escribir la fila ANTES de procesar, y marcarla procesada
--   SOLO cuando el mensaje esta guardado en `messages`.
--   MIENTRAS HERMES NO ESCRIBA, la tabla esta vacia y el vigilante no avisa
--   de nada. No molesta, pero tampoco protege.
--
-- SE DESCARTO vigilar el dinero ("entro un deposito y nadie lo reclama").
-- Medido: la cola legitima entre el correo de MMG y el comprobante del cliente
-- llega a 47,5 h (4 casos de 36 pasan de 24 h), y sobre todo el correo de MMG
-- NO dice quien deposito — solo "Hi Osmany, You have deposited $X". En 6 dias
-- entraron 68 depositos y solo se cruzaron 25: los otros 43 son en su mayoria
-- dinero del propio Osmany, y cada uno seria una alarma imposible de cerrar.
-- Ver docs/negocio/PLAN-vigilante-mensajes-perdidos.md

CREATE TABLE IF NOT EXISTS public.whatsapp_webhook_log (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recibido_en     timestamptz NOT NULL DEFAULT now(),
  phone_number_id text,
  wamid           text,
  remitente       text,          -- el numero del cliente: ESTO es lo que se vigila
  tipo            text,          -- text, image, audio...
  procesado       boolean NOT NULL DEFAULT false,
  error           text,
  payload         jsonb
);

CREATE INDEX IF NOT EXISTS idx_webhook_log_pendientes
  ON public.whatsapp_webhook_log (procesado, recibido_en);
CREATE INDEX IF NOT EXISTS idx_webhook_log_wamid
  ON public.whatsapp_webhook_log (wamid);

-- Mismo patron que depositos_mmg y cerebro_alertas: RLS puesto y SIN politicas.
-- El payload lleva mensajes de clientes; solo el rol de servicio lo toca.
ALTER TABLE public.whatsapp_webhook_log ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.whatsapp_webhook_log IS
  'Lo que Meta entrega al webhook de WhatsApp. La fila se escribe ANTES de procesar; procesado pasa a true SOLO cuando el mensaje esta guardado en messages. Retencion corta: cerebro_avisar_mensajes_perdidos() purga lo procesado y viejo.';

-- Tipo de aviso nuevo. VA ANTES de activar el workflow: el 10-ago el vigilante
-- de la ingesta quedo desplegado detectando bien y SIN PODER AVISAR porque el
-- tipo no estaba en la restriccion (ver 058).
ALTER TABLE notifications DROP CONSTRAINT notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type = ANY (ARRAY['conversation_assigned'::text,
                           'deal_incidencia'::text,
                           'mensaje_fallido'::text,
                           'promo_etecsa'::text,
                           'chat_atascado'::text,
                           'ingesta_caida'::text,
                           'deposito_sin_cruzar'::text,
                           'mensaje_perdido'::text]));

INSERT INTO cerebro_config (clave, valor) VALUES
  ('perdido_minutos','10'),         -- cuanto espera antes de avisar
  ('perdido_repetir_min','120'),    -- cada cuanto repite el aviso del mismo cliente
  ('perdido_retencion_dias','14'),  -- cuanto se guarda lo ya procesado
  ('perdido_hora_desde','9'),       -- ventana de aviso, hora de Guyana
  ('perdido_hora_hasta','17')
ON CONFLICT (clave) DO NOTHING;

-- El vigilante se hace como FUNCION, no como consulta suelta, para que el nodo
-- de n8n sea UNA sola sentencia: el nodo Postgres parte por ';' y eso ya tumbo
-- produccion una vez (ver 18-dos-caidas-silenciosas.md).
-- La ventana horaria sale de config porque si no la funcion NO SE PUEDE PROBAR
-- fuera de horario: el primer intento dio 0 en las seis caras, que es lo mismo
-- que no haber probado nada.

CREATE OR REPLACE FUNCTION public.cerebro_avisar_mensajes_perdidos(
  p_minutos integer DEFAULT NULL, p_repetir_min integer DEFAULT NULL)
 RETURNS TABLE(perdidos integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_repetir int; v_dias int; v_desde int; v_hasta int;
  v_ahora_gy timestamp;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; r record;
BEGIN
  v_min     := COALESCE(p_minutos,     NULLIF(cerebro_config_get('perdido_minutos'),     '')::int, 10);
  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('perdido_repetir_min'), '')::int, 120);
  v_dias    := COALESCE(NULLIF(cerebro_config_get('perdido_retencion_dias'), '')::int, 14);
  v_desde   := COALESCE(NULLIF(cerebro_config_get('perdido_hora_desde'), '')::int, 9);
  v_hasta   := COALESCE(NULLIF(cerebro_config_get('perdido_hora_hasta'), '')::int, 17);

  DELETE FROM whatsapp_webhook_log
   WHERE procesado = true AND recibido_en < now() - make_interval(days => v_dias);

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF (EXTRACT(DOW FROM v_ahora_gy) = 0 AND NOT (v_desde = 0 AND v_hasta >= 24))
     OR EXTRACT(hour FROM v_ahora_gy) < v_desde
     OR EXTRACT(hour FROM v_ahora_gy) >= v_hasta THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  FOR r IN
    SELECT w.remitente,
           count(*)                                    AS cuantos,
           min(w.recibido_en)                          AS primero,
           coalesce(max(w.error), 'sin detalle')       AS motivo,
           coalesce(
             (SELECT wc.account_id FROM whatsapp_config wc
               WHERE wc.phone_number_id = max(w.phone_number_id)),
             (SELECT wc2.account_id FROM whatsapp_config wc2 LIMIT 1)) AS account_id
      FROM whatsapp_webhook_log w
     WHERE w.procesado = false
       AND w.remitente IS NOT NULL
       AND w.recibido_en < now() - make_interval(mins => v_min)
       -- Un mensaje perdido hace tres dias ya no se arregla avisando; lo unico
       -- que consigue es tener la campana sonando para siempre.
       AND w.recibido_en > now() - interval '24 hours'
     GROUP BY w.remitente
    HAVING NOT EXISTS (
       SELECT 1 FROM cerebro_alertas a
        WHERE a.clave = 'mensaje_perdido:' || w.remitente
          AND a.ultimo > now() - make_interval(mins => v_repetir))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - r.primero)) >= 3600
        THEN round(EXTRACT(EPOCH FROM (now() - r.primero)) / 3600)::text || ' h'
      ELSE round(EXTRACT(EPOCH FROM (now() - r.primero)) / 60)::text || ' min' END;

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT r.account_id, p.user_id, 'mensaje_perdido',
           'Mensaje de ' || r.remitente || ' NO llego al CRM (' || r.cuantos || ')',
           'El cliente ' || r.remitente || ' escribio hace ' || v_espera ||
           ' y su mensaje NO se guardo. El ve doble tick de entregado.' ||
           chr(10) || chr(10) ||
           'Mensajes afectados: ' || r.cuantos || '. Motivo: ' || r.motivo ||
           chr(10) || chr(10) ||
           'Hay que escribirle a mano. No espera respuesta del bot: el bot nunca vio el mensaje.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('mensaje_perdido:' || r.remitente, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END $function$;

-- WORKFLOW: `Vigilante - mensajes de clientes perdidos` (HVNAIc8otXHejsw4),
-- cada 10 minutos, un solo nodo: SELECT * FROM cerebro_avisar_mensajes_perdidos()
--
-- COMO SE PROBO (filas fabricadas dentro de un bloque que se revierte, y con
-- la ventana horaria abierta a 0-24 SOLO dentro de ese bloque)
--   1) tabla vacia                     -> 0 avisos                        OK
--   2) una fila sin procesar, 20 min   -> 1 perdido, 3 avisos (un admin
--                                         cada uno)                       OK
--   3) repetir enseguida               -> 0 avisos (throttle)             OK
--   4) tres filas del mismo remitente  -> 1 perdido, 3 avisos, y el titulo
--                                         dice "(3)" — no nueve avisos    OK
--   5) fila de hace 30 h               -> 0 avisos (ventana de 24 h)      OK
--   6) fila ya procesada               -> 0 avisos                        OK
--   7) fila de hace 3 min (umbral 10)  -> 0 avisos                        OK
--   Despues: 0 filas, 0 avisos, 0 throttles y la config en 9-17.
--
-- LO QUE ESTO NO CUBRE
--   Que Meta no entregue el webhook. Si la peticion nunca llega al VPS no hay
--   fila que vigilar, y eso solo se ve en el panel de entregas de Meta.
--
-- AJUSTES EN CALIENTE
--   UPDATE cerebro_config SET valor='15' WHERE clave='perdido_minutos';
--   UPDATE cerebro_config SET valor='7'  WHERE clave='perdido_retencion_dias';
--
-- REVERSION
--   Desactivar HVNAIc8otXHejsw4. La tabla y el tipo de aviso pueden quedarse.

-- ---------------------------------------------------------------------------
-- 061d — PERMISOS DE TABLA PARA service_role  (anadido el mismo dia, tras
--        fallar en produccion con un mensaje real)
--
-- EL FALLO
-- La tabla se creo con RLS y sin politicas, copiando el patron de
-- depositos_mmg. Pero depositos_mmg solo la toca n8n, que entra por conexion
-- Postgres directa; WaCRM entra por PostgREST con la clave de service_role.
--
-- Y `service_role` SE SALTA EL RLS, PERO NO LOS PERMISOS DE TABLA:
--
--   [webhook] no se pudo registrar en whatsapp_webhook_log:
--     permission denied for table whatsapp_webhook_log
--
-- El mensaje del cliente se guardo bien —el INSERT del log lleva su propio
-- try/catch a proposito— pero la fila del rastro nunca se escribio: el
-- vigilante habria quedado CIEGO sin que nada lo indicara. Justo el fallo que
-- este vigilante existe para evitar.
--
-- POR QUE NO LO VIO NINGUNA PRUEBA
-- Las siete pruebas en SQL corren como `postgres`, que tiene todos los
-- permisos. Solo aparecio al mandar un mensaje de WhatsApp de verdad. Es
-- exactamente la regla de 19-que-se-le-pide-al-cliente.md: una rama que no se
-- ha visto producir un mensaje real no esta probada.
--
-- SOLO service_role. Ni anon ni authenticated: el payload lleva mensajes de
-- clientes y no tiene por que ser accesible desde el navegador. El RLS sigue
-- puesto y sin politicas como segunda barrera.

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.whatsapp_webhook_log TO service_role;

-- COMPROBACION
--   SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type)
--     FROM information_schema.role_table_grants
--    WHERE table_schema='public' AND table_name='whatsapp_webhook_log'
--    GROUP BY grantee;
--   -> service_role con DELETE,INSERT,SELECT,UPDATE; anon y authenticated sin
--      acceso a datos.
