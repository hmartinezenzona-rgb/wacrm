-- =====================================================================
-- 050 — Confirmar una promocion desde el CRM, sin SQL
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- POR QUE
--
--   La 047 dejo la confirmacion como `cerebro_promo_confirmar(uuid)`.
--   Eso lo puede llamar Humberto por SQL, pero **Osmany no ejecuta SQL**,
--   asi que en la practica el ciclo estaba a medias.
--
--   Esto le quita trabajo a Hermes: en vez de tener que sacar el id de
--   la promo desde la notificacion —que no lleva referencia—, el boton
--   del CRM llama a dos funciones sin parametros.
--
-- ROLLBACK
--   DROP FUNCTION IF EXISTS cerebro_promo_confirmar_pendiente(text);
--   DROP FUNCTION IF EXISTS cerebro_promo_pendiente();
-- =====================================================================

-- Que hay pendiente (para saber si mostrar el boton, y que texto poner)
CREATE OR REPLACE FUNCTION cerebro_promo_pendiente()
RETURNS TABLE (id uuid, min_cup numeric, max_cup numeric, multiplicador numeric,
               precio_gyd numeric, vigente_desde date, vigente_hasta date,
               resumen text, hay_precio boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.min_cup, p.max_cup, p.multiplicador, r.precio_gyd,
         p.vigente_desde, p.vigente_hasta,
         format('%s-%s CUP x%s, del %s al %s%s',
                p.min_cup, p.max_cup, p.multiplicador,
                to_char(p.vigente_desde,'DD/MM'), to_char(p.vigente_hasta,'DD/MM'),
                CASE WHEN r.precio_gyd IS NULL THEN ' (SIN PRECIO DEFINIDO)'
                     ELSE ' - ' || r.precio_gyd || ' GYD' END) AS resumen,
         (r.precio_gyd IS NOT NULL) AS hay_precio
    FROM promo_etecsa p
    LEFT JOIN precio_recarga r ON r.min_cup = p.min_cup
   WHERE p.estado = 'detectada'
     AND p.vigente_hasta >= current_date
   ORDER BY p.vigente_desde;
$$;

-- Confirmar sin id. **Misma filosofia que `cerebro_resolver_operacion`:
-- si hay mas de una candidata, NO adivina.**
CREATE OR REPLACE FUNCTION cerebro_promo_confirmar_pendiente(p_quien text DEFAULT 'crm')
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int; v_id uuid; v_res text;
BEGIN
  SELECT count(*) INTO v_n FROM cerebro_promo_pendiente();
  IF v_n = 0 THEN RETURN 'no hay ninguna promocion pendiente de confirmar'; END IF;
  IF v_n > 1 THEN
    RETURN format('hay %s promociones pendientes: confirmelas una a una, no se puede adivinar cual', v_n);
  END IF;
  SELECT id INTO v_id FROM cerebro_promo_pendiente();
  SELECT cerebro_promo_confirmar(v_id, p_quien) INTO v_res;
  RETURN v_res;
END $$;

-- Sin esto el CRM no las puede llamar por RPC.
GRANT EXECUTE ON FUNCTION cerebro_promo_pendiente() TO authenticated;
GRANT EXECUTE ON FUNCTION cerebro_promo_confirmar_pendiente(text) TO authenticated;


-- =====================================================================
-- COMO SE PROBO (9-ago-2026), en bloque revertido
--
--   A. sin pendientes    -> "no hay ninguna promocion pendiente"
--   B. una pendiente     -> "confirmada: 500-1000 CUP x5", estado pasa
--                            a 'confirmada'
--   C. DOS pendientes    -> "hay 2 promociones pendientes: confirmelas
--                            una a una, no se puede adivinar cual"
--
--   El caso C es el que importa: no elige por su cuenta.
-- =====================================================================
