-- =====================================================================
-- 049 — El bot informa de la promocion ANTES de que empiece
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- EL FALLO QUE ARREGLA (lo vio Humberto, no yo)
--
--   La 047 solo miraba promociones VIGENTES HOY. Una promocion
--   confirmada pero futura era invisible para el agente: el bot no podia
--   ni decir "empieza el 13".
--
--   Y eso es justo lo que necesitaba un cliente real el 9-ago: pregunto
--   "la recarga del 13 al 16 que se multiplica por 6, cuando empesara?"
--   y se quedo esperando atencion humana mas de cinco horas.
--
-- LA DISTINCION QUE FALTABA
--
--   **Informar no es vender.** Son dos cosas distintas y hasta ahora
--   estaban mezcladas:
--
--     Promo VIGENTE hoy  -> el bot cotiza y cobra  (requiere_humano=false)
--     Promo PROXIMA      -> el bot INFORMA fecha y precio, pero NO cobra
--     Ninguna            -> deriva, como siempre
--
--   El caso del medio es el que se añade. `requiere_humano` NO baja: no
--   se puede aplicar todavia, asi que sigue ofreciendo el operador.
--
-- ROLLBACK
--   Restaurar `cerebro_servicio_get` de la 047 (solo el COALESCE de dos
--   ramas) y:
--   DROP FUNCTION IF EXISTS cerebro_promo_proxima();
--   DELETE FROM cerebro_config WHERE clave='promo_etecsa_avisar_dias_antes';
-- =====================================================================

-- Con cuanta antelacion se informa. Configurable sin desplegar.
INSERT INTO cerebro_config (clave, valor, descripcion) VALUES
  ('promo_etecsa_avisar_dias_antes', '7',
   'Con cuantos dias de antelacion el bot INFORMA de una promocion confirmada que aun no ha empezado. Informar no es vender: hasta la fecha de inicio no se puede aplicar.')
ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, actualizado = now();


CREATE OR REPLACE FUNCTION cerebro_promo_proxima()
RETURNS TABLE (min_cup numeric, max_cup numeric, multiplicador numeric,
               precio_gyd numeric, vigente_desde date, vigente_hasta date, dias_para int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.min_cup, p.max_cup, p.multiplicador, r.precio_gyd,
         p.vigente_desde, p.vigente_hasta,
         (p.vigente_desde - current_date)::int AS dias_para
    FROM promo_etecsa p
    JOIN precio_recarga r ON r.min_cup = p.min_cup
   WHERE p.vigente_desde > current_date
     AND p.vigente_desde <= current_date
         + (coalesce(cerebro_config_get('promo_etecsa_avisar_dias_antes'),'7'))::int
     AND (p.estado = 'confirmada'
          OR (p.estado = 'detectada'
              AND coalesce(cerebro_config_get('promo_etecsa_modo'),'confirmar') = 'automatico'))
   ORDER BY p.vigente_desde
   LIMIT 1;
$$;


-- `cerebro_servicio_get` pasa a tener TRES ramas para recargas.
-- El texto va como mapeo plano, sin lenguaje deliberativo: ver
-- 11-lenguaje-deliberativo-rompe-deepseek.md.

CREATE OR REPLACE FUNCTION cerebro_servicio_get(p_busqueda text DEFAULT NULL::text)
RETURNS TABLE(nombre text, hechos text, enlace text, requiere_humano boolean, notas_internas text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT s.nombre,
         CASE WHEN s.clave = 'recargas' THEN
           s.hechos || E'\n' || COALESCE(
             (SELECT format('PROMOCION VIGENTE HOY: se recarga el minimo de %s CUP y el cliente recibe x%s. Precio para el cliente: %s GYD. Valida hasta el %s.',
                            v.min_cup, v.multiplicador, v.precio_gyd, to_char(v.vigente_hasta,'DD/MM'))
                FROM cerebro_promo_vigente() v),
             (SELECT format('PROXIMA PROMOCION, EMPIEZA EL %s (en %s dias) y dura hasta el %s: se recargara el minimo de %s CUP y el cliente recibira x%s, precio %s GYD. HOY NO SE PUEDE APLICAR TODAVIA. Di la fecha y el precio si preguntan. No cobres recargas hasta esa fecha.',
                            to_char(p.vigente_desde,'DD/MM'), p.dias_para, to_char(p.vigente_hasta,'DD/MM'),
                            p.min_cup, p.multiplicador, p.precio_gyd)
                FROM cerebro_promo_proxima() p),
             'HOY NO HAY PROMOCION CONFIRMADA. No cotices recargas: ofrece pasar con un operador.')
         ELSE s.hechos END AS hechos,
         s.enlace,
         CASE WHEN s.clave = 'recargas' AND EXISTS (SELECT 1 FROM cerebro_promo_vigente())
              THEN false ELSE s.requiere_humano END AS requiere_humano,
         s.notas_internas
    FROM cerebro_servicios s
   WHERE s.activo
     AND (NULLIF(p_busqueda,'') IS NULL
          OR s.clave = lower(trim(p_busqueda))
          OR s.nombre ILIKE '%'||trim(p_busqueda)||'%')
   ORDER BY s.nombre;
$$;


-- =====================================================================
-- COMO SE PROBO (9-ago-2026)
--
--   Con el agente REAL, haciendole la misma pregunta que hizo el cliente
--   de esa mañana. Respondio:
--
--     "La proxima promocion de Etecsa empieza el *13 de agosto* y dura
--      hasta el *16*. Se recarga el minimo de *600 CUP* y el cliente
--      recibe *x6*, a un precio de *6,200 GYD*.
--      Hoy todavia no se puede aplicar, pero apenas llegue la fecha la
--      hacemos. Si quiere, le paso con un operador."
--
--   Fecha, precio, y deja claro que hoy no se aplica. Sin tocar el
--   prompt ni el workflow.
-- =====================================================================
