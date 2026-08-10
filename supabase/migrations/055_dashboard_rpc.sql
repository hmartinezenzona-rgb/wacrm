-- =====================================================================
-- 055 — Las funciones que lee la pantalla /resumen del CRM
--
--   YA APLICADA EN PRODUCCION EL 10-AGO-2026 (00:00 UTC). NO LA REPITAS.
--
-- POR QUE FUNCIONES Y NO LAS VISTAS DIRECTAMENTE
--
--   `remittance_operations` y `remittance_beneficiaries` tienen **RLS
--   activo y NINGUNA politica**. Un `SELECT` desde el cliente con el rol
--   `authenticated` devolveria **vacio, sin error** — el peor tipo de
--   fallo, porque parece "no hay datos" en vez de "no tienes permiso".
--
--   El Cerebro no lo nota porque n8n entra por conexion directa de
--   Postgres, que salta RLS. Pero el CRM sí.
--
--   Estas funciones son `SECURITY DEFINER` con `GRANT EXECUTE` a
--   `authenticated`: exponen lo justo sin abrir las tablas. Es el mismo
--   patron de `cerebro_promo_pendiente`.
--
-- ROLLBACK
--   DROP FUNCTION IF EXISTS cerebro_dashboard_historial(date,date,text,int);
--   DROP FUNCTION IF EXISTS cerebro_dashboard_resumen();
-- =====================================================================

-- Higiene: las vistas de la 053 heredaron permisos para `anon` que no
-- pintaban nada ahi.
REVOKE ALL ON cerebro_resumen_volumen, cerebro_volumen_diario,
              cerebro_historial_operaciones FROM anon;


CREATE OR REPLACE FUNCTION cerebro_dashboard_resumen()
RETURNS TABLE (orden int, periodo text, desde date, hasta date,
               operaciones bigint, volumen_gyd numeric, ticket_medio_gyd numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT r.orden, r.periodo, r.desde, r.hasta,
         r.operaciones, r.volumen_gyd, r.ticket_medio_gyd
    FROM cerebro_resumen_volumen r ORDER BY r.orden;
$$;


CREATE OR REPLACE FUNCTION cerebro_dashboard_historial(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_servicio text DEFAULT NULL, p_limite int DEFAULT 200
)
RETURNS TABLE (dia date, service_type text, status text, cliente text,
               telefono text, monto_gyd numeric, beneficiario text,
               tarjeta text, operation_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT h.dia, h.service_type, h.status, h.cliente, h.telefono,
         h.monto_gyd, h.beneficiario, h.tarjeta, h.operation_id
    FROM cerebro_historial_operaciones h
   WHERE (p_desde IS NULL OR h.dia >= p_desde)
     AND (p_hasta IS NULL OR h.dia <= p_hasta)
     AND (p_servicio IS NULL OR h.service_type = p_servicio)
   ORDER BY h.dia DESC, h.monto_gyd DESC
   LIMIT least(coalesce(p_limite, 200), 1000);
$$;

GRANT EXECUTE ON FUNCTION cerebro_dashboard_resumen() TO authenticated;
GRANT EXECUTE ON FUNCTION cerebro_dashboard_historial(date,date,text,int) TO authenticated;


-- =====================================================================
-- QUIEN LAS USA
--   `src/app/(dashboard)/resumen/page.tsx` en WaCRM (Hermes, 10-ago).
--   Enlace en el menu lateral. Verificado: /resumen devuelve 200 y los
--   numeros cuadran con la base.
--
-- LA TARJETA VA ENMASCARADA (9205****9412) a proposito. Si algun dia se
-- necesita completa para un informe, hace falta OTRA funcion — no
-- ampliar esta.
--
-- CUANDO LLEGUE EL COSTE DEL CUP
--   La ganancia entra como **una columna mas** en estas dos funciones.
--   La forma que devuelven no cambia, asi que la pantalla de Hermes no
--   hay que rehacerla.
-- =====================================================================
