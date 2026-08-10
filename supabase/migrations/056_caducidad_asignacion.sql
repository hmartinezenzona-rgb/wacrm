-- =====================================================================
-- 056 — Una asignacion manual de chat caduca sola
--
--   YA APLICADA EN PRODUCCION EL 10-AGO-2026 (13:34 UTC). NO LA REPITAS.
--
-- QUE PASO
--
--   Primer lunes con trafico real. Al cliente 5926082754 el bot no le
--   contesto nada en toda la mañana. No fallo nada: **20 ejecuciones
--   seguidas** terminaron en
--       {"ruta":"silencio","motivo":"chat asignado a humano"}
--   El chat llevaba dias asignado a un operador y **una asignacion no
--   caducaba nunca**. Habia 8 chats mas igual de mudos, hasta de 4 dias
--   atras, y nadie se entero: un chat asignado NO genera ninguna alerta.
--
-- QUE HACE
--
--   Pasados N minutos sin actividad humana, la asignacion MANUAL se
--   libera sola. Quien libera es la query del nodo `Contexto
--   conversacion` del Cerebro (workflow T3v07IQqtMs6AKJ4), que trae un
--   CTE `caducar`. El plazo vive en cerebro_config y se toca sin
--   desplegar nada:
--
--     UPDATE cerebro_config SET valor = '15'
--      WHERE clave = 'asignacion_caduca_minutos';
--
-- POR QUE LIBERA DE VERDAD EN VEZ DE IGNORAR LA ASIGNACION
--
--   Poner assigned_agent_id a NULL dispara `trg_limpiar_memoria_al_liberar`
--   (migracion previa), que le deja al bot la marca "ATENCION HUMANA YA
--   TERMINADA" para que no anuncie una derivacion muerta. Ignorar el
--   campo habria dejado esa maquinaria sin usar y habria hecho falta
--   duplicarla.
--
-- LAS DOS TRAMPAS, que son la razon de este fichero
--
--   1. `conversations.updated_at` NO SIRVE DE RELOJ. Se toca en cada
--      mensaje, tambien en los del cliente (lo mantiene el disparador
--      `set_updated_at`). Con un cliente escribiendo, la asignacion no
--      caducaria JAMAS. De ahi la columna `assigned_at`, que solo se
--      mueve cuando el chat cambia de manos. Comprobado: tras un mensaje
--      nuevo, updated_at salto a 13:35 y assigned_at siguio en 13:05.
--
--   2. LAS DERIVACIONES DEL PROPIO BOT NO CADUCAN. `derivar_humano` y el
--      control de abuso asignan al perfil
--      377b0c8c-c025-46ff-8088-7a929080831e. Si el bot derivo fue porque
--      no sabia seguir; retomar a los 10 minutos seria peor que el
--      problema que arreglamos.
--
--      OJO: ese 377b0c8c es un `profiles.id`, mientras que WaCRM escribe
--      en assigned_agent_id el `auth.users.id`. Es una incoherencia real
--      (los chats que deriva el bot quedan asignados a un usuario que la
--      UI no resuelve) que aqui nos viene bien porque distingue las dos
--      clases de asignacion. SI SE ARREGLA, HAY QUE CAMBIAR A LA VEZ EL
--      DISCRIMINANTE DEL CTE `caducar`.
--
-- ROLLBACK — EN ESTE ORDEN
--   1) Restaurar el workflow desde
--      ROLLBACK-v2-antes-caducar-asignacion.json. Si se hace al reves, la
--      query del nodo referencia una columna que ya no existe y REVIENTA
--      EN CADA EJECUCION.
--   2) DROP TRIGGER IF EXISTS trg_cerebro_marcar_asignacion ON conversations;
--      DROP FUNCTION IF EXISTS cerebro_marcar_asignacion();
--      ALTER TABLE conversations DROP COLUMN IF EXISTS assigned_at;
--      DELETE FROM cerebro_config WHERE clave = 'asignacion_caduca_minutos';
-- =====================================================================

ALTER TABLE conversations ADD COLUMN IF NOT EXISTS assigned_at timestamptz;

COMMENT ON COLUMN conversations.assigned_at IS
  'Cuando el chat paso a manos de esta persona. Lo mantiene el disparador '
  'trg_cerebro_marcar_asignacion. NULL = sin asignar, o asignado antes de la '
  'migracion 056 (se trata como caducado).';


CREATE OR REPLACE FUNCTION cerebro_marcar_asignacion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Solo toca assigned_at cuando el chat cambia de manos de verdad.
  -- Un mensaje nuevo actualiza la fila entera pero no debe mover el reloj.
  IF TG_OP = 'INSERT' THEN
    IF NEW.assigned_agent_id IS NOT NULL THEN
      NEW.assigned_at := now();
    END IF;
  ELSIF NEW.assigned_agent_id IS DISTINCT FROM OLD.assigned_agent_id THEN
    NEW.assigned_at := CASE
                         WHEN NEW.assigned_agent_id IS NULL THEN NULL
                         ELSE now()
                       END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cerebro_marcar_asignacion ON conversations;
CREATE TRIGGER trg_cerebro_marcar_asignacion
  BEFORE INSERT OR UPDATE ON conversations
  FOR EACH ROW
  EXECUTE FUNCTION cerebro_marcar_asignacion();


-- Los 9 chats que ya estaban asignados se quedan con assigned_at NULL a
-- proposito: la query cae entonces en el ultimo mensaje humano, que es el dato
-- honesto. Los 8 abandonados se liberan en cuanto el cliente vuelva a escribir
-- —justo cuando importa—, y el que estaba siendo atendido sigue en silencio
-- porque su operador acababa de hablar. Por eso NO hay UPDATE de arrastre aqui.

INSERT INTO cerebro_config (clave, valor, descripcion, actualizado)
VALUES ('asignacion_caduca_minutos', '10',
        'Minutos sin actividad humana tras los que una asignacion MANUAL se '
        'libera sola. Las derivaciones del propio bot (perfil 377b0c8c...) no '
        'caducan nunca. La ventana corta de 5 min del Decisor sigue aparte.',
        now())
ON CONFLICT (clave) DO UPDATE
  SET valor = EXCLUDED.valor,
      descripcion = EXCLUDED.descripcion,
      actualizado = now();


-- =====================================================================
-- QUIEN LA USA
--   El nodo `Contexto conversacion` del Cerebro (T3v07IQqtMs6AKJ4). El
--   parche esta en ~/cerebro-fase1/patch-caducar-asignacion.py y es un
--   cambio de PARAMETRO, no de estructura: n8n lo aplica sin
--   desactivar/activar y sin cortar webhooks.
--
--   WaCRM no toca nada de esto. El chat sigue viendose y asignandose
--   igual; lo unico que cambia es cuanto tiempo eso calla al bot.
--
-- PROBADO DE PUNTA A PUNTA (ejecucion 26656, conversacion de pruebas)
--   Asignacion simulada de hace 30 min -> `asignado: false`, ruta
--   `agente`, el bot cotizo 20.000 GYD -> 60.000 CUP y NO menciono la
--   derivacion. 0 deals creados. Rastro de la prueba limpiado.
--
-- LO QUE SIGUE SIN CUBRIR
--   Un chat asignado sigue sin generar alerta. La caducidad hace que ya
--   no importe para el bot, pero si alguien quiere saber que un operador
--   dejo un chat a medias, eso es un vigilante aparte.
-- =====================================================================
