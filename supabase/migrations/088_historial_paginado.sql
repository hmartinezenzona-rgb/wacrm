-- =====================================================================
-- 088 — El historial de /resumen se pagina
--
-- EL PROBLEMA (medido el 14-ago-2026)
--
--   La pantalla pedia `p_limite: 200` y pintaba las 200 filas de un
--   tiro. Hoy hay **95 filas en 6 dias** — unas **16 al dia**. A ese
--   ritmo el tope de 200 se alcanza **alrededor del 26-ago**, y lo que
--   pasa entonces es peor que una tabla larga: la funcion **corta en
--   silencio**. Nadie ve un aviso; las operaciones viejas simplemente
--   dejan de estar, y el unico modo de alcanzarlas seria adivinar
--   fechas en el filtro. Es la misma enfermedad de la columna
--   "Entregada" del tablero, que crecia sin fin.
--
-- QUE CAMBIA
--
--   1. `p_desde_fila` (OFFSET): la pantalla pide de 25 en 25.
--   2. Columna `total`: cuantas filas hay en TODO el filtro, no en la
--      pagina. Sin ella la pantalla no puede decir "1–25 de 137" ni
--      saber si hay pagina siguiente. Se calcula con `count(*) OVER ()`,
--      que se evalua ANTES del LIMIT: por eso vale el total real.
--   3. Desempate en el ORDER BY. Esto NO es cosmetico: con OFFSET, dos
--      filas empatadas pueden salir en distinto orden en dos llamadas
--      distintas, y entonces una fila aparece en dos paginas mientras
--      otra no aparece en ninguna. Y hay empates de verdad: la
--      operacion 1054d03b (Alexander, 12-ago, 30.000) tiene TRES
--      beneficiarios vigentes, o sea tres filas identicas en
--      (dia, monto, operation_id). Se desempata por tarjeta y nombre.
--
-- QUE NO CAMBIA — a proposito
--
--   `p_limite` sigue con DEFAULT 200 y el mismo tope de 1000. La
--   pantalla que hay desplegada ahora mismo llama con cuatro argumentos
--   (`p_desde`, `p_hasta`, `p_servicio`, `p_limite: 200`) y **debe
--   seguir funcionando igual** entre esta migracion y el despliegue del
--   front: `p_desde_fila` tiene default, asi que esa llamada de cuatro
--   sigue casando, y la columna `total` de mas la ignora el cliente.
--
-- OJO CON LOS PERMISOS
--
--   Hay que DROPear porque cambia el tipo de retorno, y al DROPear se
--   van los GRANT. La 064 dejo `ALTER DEFAULT PRIVILEGES ... REVOKE
--   EXECUTE ... FROM authenticated`, o sea que la funcion nueva nace
--   SIN permiso para el navegador. Sin el GRANT de abajo, /resumen
--   responde "permission denied for function". Se replica exactamente
--   lo que tenia: authenticated + service_role.
--
--   (No basto: ver la 088b — la funcion nueva nacio ADEMAS con EXECUTE
--   para PUBLIC, o sea ejecutable por `anon`.)
--
-- PROBADO ANTES DE APLICAR
--   Las 4 paginas de 25 sobre las 95 filas reales: 95 filas recogidas,
--   0 sobran, 0 faltan, `total` = 95 en las cuatro.
--
-- ROLLBACK
--   Recrear la version de la 055 (4 argumentos, sin `total`) y volver a
--   dar GRANT EXECUTE ... TO authenticated, service_role.
-- =====================================================================

DROP FUNCTION IF EXISTS public.cerebro_dashboard_historial(date, date, text, integer);

CREATE FUNCTION public.cerebro_dashboard_historial(
  p_desde      date    DEFAULT NULL,
  p_hasta      date    DEFAULT NULL,
  p_servicio   text    DEFAULT NULL,
  p_limite     integer DEFAULT 200,
  p_desde_fila integer DEFAULT 0
)
RETURNS TABLE (dia date, service_type text, status text, cliente text,
               telefono text, monto_gyd numeric, beneficiario text,
               tarjeta text, operation_id uuid, total bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH filtrado AS (
    SELECT h.dia, h.service_type, h.status, h.cliente, h.telefono,
           h.monto_gyd, h.beneficiario, h.tarjeta, h.operation_id
      FROM cerebro_historial_operaciones h
     WHERE (p_desde IS NULL OR h.dia >= p_desde)
       AND (p_hasta IS NULL OR h.dia <= p_hasta)
       AND (p_servicio IS NULL OR h.service_type = p_servicio)
  )
  SELECT f.dia, f.service_type, f.status, f.cliente, f.telefono,
         f.monto_gyd, f.beneficiario, f.tarjeta, f.operation_id,
         count(*) OVER () AS total
    FROM filtrado f
   ORDER BY f.dia DESC, f.monto_gyd DESC, f.operation_id,
            f.tarjeta NULLS LAST, f.beneficiario NULLS LAST
   LIMIT  least(coalesce(p_limite, 200), 1000)
  OFFSET greatest(coalesce(p_desde_fila, 0), 0);
$$;

GRANT EXECUTE ON FUNCTION
  public.cerebro_dashboard_historial(date, date, text, integer, integer)
TO authenticated, service_role;

-- PostgREST cachea la firma de las funciones. Sin esto, la pantalla
-- nueva (que manda 5 argumentos) podria oir "no existe esa funcion"
-- hasta el siguiente recargado de esquema.
NOTIFY pgrst, 'reload schema';
