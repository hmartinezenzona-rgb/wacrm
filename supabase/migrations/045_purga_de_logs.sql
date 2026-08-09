-- =====================================================================
-- 045 — Higiene: purga automatica de logs
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- Cierra el punto 5 de PENDIENTES ("cerebro_ejecuciones crece sin
-- limite"). Habilita `pg_cron` y programa una purga semanal.
--
-- CONTEXTO MEDIDO ANTES DE HACERLO — importa, porque relativiza el
-- problema:
--
--   depositos_mmg        661 filas   944 kB
--   cerebro_memoria      587 filas   744 kB
--   messages             972 filas   672 kB
--   session_events       426 filas   344 kB
--   cerebro_ejecuciones  296 filas   160 kB   <- "crece sin limite"
--
--   Toda la base son unos pocos MB. A este ritmo `cerebro_ejecuciones`
--   sumaria ~12 MB al año. **No era un problema hoy ni en muchos meses.**
--   Se hace porque es barato y quita un pendiente para siempre, no
--   porque corriera prisa.
--
-- ROLLBACK
--   SELECT cron.unschedule('cerebro-purgar-logs');
--   DROP FUNCTION IF EXISTS cerebro_purgar_logs();
--   -- y si se quiere dejar la base como estaba:
--   -- DROP EXTENSION IF EXISTS pg_cron;
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE OR REPLACE FUNCTION cerebro_purgar_logs()
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ejec int := 0;
  v_tool int := 0;
BEGIN
  -- Ejecuciones del Cerebro: solo trazabilidad. A los 30 dias no sirven
  -- para nada y ninguna consulta de vigilancia mira tan atras.
  DELETE FROM cerebro_ejecuciones WHERE created_at < now() - interval '30 days';
  GET DIAGNOSTICS v_ejec = ROW_COUNT;

  -- Log de llamadas a tools (tramo 2D). Se guarda mas tiempo porque es
  -- lo unico que permite auditar quien escribio que en una operacion.
  IF to_regclass('public.tool_execution_log') IS NOT NULL THEN
    DELETE FROM tool_execution_log WHERE created_at < now() - interval '90 days';
    GET DIAGNOSTICS v_tool = ROW_COUNT;
  END IF;

  RETURN format('purgadas %s ejecuciones y %s llamadas a tools', v_ejec, v_tool);
EXCEPTION WHEN OTHERS THEN
  -- Misma regla que el resto: una purga que falla no puede tumbar nada.
  RAISE WARNING '[cerebro] purga de logs fallo: %', SQLERRM;
  RETURN 'fallo: ' || SQLERRM;
END $$;

-- Domingos 07:00 UTC = 03:00 en Guyana. Negocio cerrado (L-S 9:00-17:00).
SELECT cron.schedule('cerebro-purgar-logs', '0 7 * * 0',
                     'SELECT cerebro_purgar_logs();');


-- ---------------------------------------------------------------------
-- LO QUE NO SE PURGA, Y POR QUE
-- ---------------------------------------------------------------------
--
-- `cerebro_memoria` (587 filas, 744 kB) es lo que MAS crece de todo, y
-- aun asi NO se toca: es la memoria del agente. Borrarla de una
-- conversacion viva le hace perder el contexto. Si algun dia molesta, lo
-- correcto es purgar solo conversaciones sin actividad reciente, y eso
-- es una decision de negocio (¿cuanto debe recordar el bot a un cliente
-- que vuelve tras meses?), no higiene.
--
-- `cerebro_reintentos` (0 filas) sigue huerfana a proposito: se conserva
-- por si hay que volver al Cerebro v1. Se borra cuando se jubile el v1,
-- igual que el `?secret=` de WaCRM.
--
-- `session_events`, `messages`, `depositos_mmg`, `comprobantes_hashes`
-- son datos de negocio o de auditoria. No se purgan.
--
-- ---------------------------------------------------------------------
-- VERIFICAR
-- ---------------------------------------------------------------------
--   SELECT jobid, schedule, active FROM cron.job
--    WHERE jobname = 'cerebro-purgar-logs';
--   SELECT * FROM cron.job_run_details
--    WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname='cerebro-purgar-logs')
--    ORDER BY start_time DESC LIMIT 5;
--
-- Probado el 9-ago: devolvio "purgadas 0 ejecuciones y 0 llamadas a
-- tools", que es lo correcto con una base de 5 dias.
-- =====================================================================
