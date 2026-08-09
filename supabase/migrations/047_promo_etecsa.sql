-- =====================================================================
-- 047 — Promociones de Etecsa: de derivar a cotizar solo
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- Hoy el bot NO cotiza recargas porque no tiene donde consultar que
-- promocion esta vigente. Esto le da ese sitio, con un interruptor para
-- pasar de "lo confirma una persona" a "automatico" sin desplegar nada.
--
-- EL PRINCIPIO: el scraper PROPONE, una persona CONFIRMA — hasta que
-- demuestre ser fiable. Y si algo falla, el bot deriva como hasta ahora.
-- Nunca cotiza con un dato dudoso.
--
-- ROLLBACK
--   Restaurar `cerebro_servicio_get` sin el bloque de recargas (ver 046
--   o el historial), y:
--   DROP FUNCTION IF EXISTS cerebro_promo_vigente();
--   DROP FUNCTION IF EXISTS cerebro_promo_registrar(numeric,numeric,numeric,date,date,text,text,text);
--   DROP FUNCTION IF EXISTS cerebro_promo_confirmar(uuid,text);
--   DROP TABLE IF EXISTS promo_etecsa;
--   DROP TABLE IF EXISTS precio_recarga;
--   DELETE FROM cerebro_config WHERE clave='promo_etecsa_modo';
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Lo que Etecsa anuncia (dato externo)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS promo_etecsa (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  min_cup         numeric NOT NULL,
  max_cup         numeric,
  multiplicador   numeric,
  vigente_desde   date NOT NULL,
  vigente_hasta   date NOT NULL,
  titulo          text,
  url             text,
  texto_crudo     text,          -- lo leido, para poder auditar el parseo
  estado          text NOT NULL DEFAULT 'detectada',
  detectada_at    timestamptz NOT NULL DEFAULT now(),
  confirmada_at   timestamptz,
  confirmada_por  text,
  huella          text UNIQUE,   -- evita re-detectar lo mismo en cada pasada
  CONSTRAINT promo_estado_chk CHECK (estado IN ('detectada','confirmada','descartada')),
  CONSTRAINT promo_fechas_chk CHECK (vigente_hasta >= vigente_desde)
);

CREATE INDEX IF NOT EXISTS promo_vigencia_idx ON promo_etecsa (vigente_desde, vigente_hasta)
  WHERE estado IN ('detectada','confirmada');


-- ---------------------------------------------------------------------
-- 2. Lo que cobra el negocio (dato propio)
-- ---------------------------------------------------------------------
-- IMPORTANTE: esto NO sale de Etecsa. Lo pone Osmany. Si aparece una
-- promo que empiece en un monto sin precio aqui, el bot NO cotiza y
-- avisa — es la degradacion segura, no un fallo.

CREATE TABLE IF NOT EXISTS precio_recarga (
  min_cup     numeric PRIMARY KEY,
  precio_gyd  numeric NOT NULL,
  actualizado timestamptz NOT NULL DEFAULT now()
);

INSERT INTO precio_recarga (min_cup, precio_gyd) VALUES (500, 5200), (600, 6200)
ON CONFLICT (min_cup) DO NOTHING;


-- ---------------------------------------------------------------------
-- 3. El interruptor
-- ---------------------------------------------------------------------
-- Pasar a automatico es UN UPDATE, no un despliegue:
--   UPDATE cerebro_config SET valor='automatico' WHERE clave='promo_etecsa_modo';

INSERT INTO cerebro_config (clave, valor, descripcion) VALUES
  ('promo_etecsa_modo', 'confirmar',
   'confirmar = una promo detectada solo se usa si la confirma una persona. automatico = se usa en cuanto se detecta. Cambiar a automatico cuando el scraper demuestre ser fiable.')
ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, actualizado = now();


-- ---------------------------------------------------------------------
-- 4. La promo utilizable HOY
-- ---------------------------------------------------------------------
-- Tres condiciones a la vez, y si falla una no devuelve nada:
--   a) dentro de fechas
--   b) con precio definido para ese minimo
--   c) confirmada, o detectada si el modo es automatico

CREATE OR REPLACE FUNCTION cerebro_promo_vigente()
RETURNS TABLE (min_cup numeric, max_cup numeric, multiplicador numeric,
               precio_gyd numeric, vigente_hasta date, estado text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.min_cup, p.max_cup, p.multiplicador, r.precio_gyd, p.vigente_hasta, p.estado
    FROM promo_etecsa p
    JOIN precio_recarga r ON r.min_cup = p.min_cup
   WHERE current_date BETWEEN p.vigente_desde AND p.vigente_hasta
     AND (p.estado = 'confirmada'
          OR (p.estado = 'detectada'
              AND coalesce(cerebro_config_get('promo_etecsa_modo'),'confirmar') = 'automatico'))
   ORDER BY p.confirmada_at DESC NULLS LAST, p.detectada_at DESC
   LIMIT 1;
$$;


-- ---------------------------------------------------------------------
-- 5. Punto de entrada del scraper
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cerebro_promo_registrar(
  p_min_cup numeric, p_max_cup numeric, p_multiplicador numeric,
  p_desde date, p_hasta date, p_titulo text, p_url text, p_texto text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_huella text; v_id uuid; v_precio numeric;
BEGIN
  v_huella := md5(concat_ws('|', p_min_cup, p_max_cup, p_multiplicador, p_desde, p_hasta));

  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde,
                            vigente_hasta, titulo, url, texto_crudo, huella)
  VALUES (p_min_cup, p_max_cup, p_multiplicador, p_desde, p_hasta,
          p_titulo, p_url, left(p_texto, 4000), v_huella)
  ON CONFLICT (huella) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN 'ya conocida, sin cambios';
  END IF;

  SELECT precio_gyd INTO v_precio FROM precio_recarga WHERE min_cup = p_min_cup;

  -- Aviso EN EL CRM, que no depende de la ventana de 24 h de WhatsApp.
  INSERT INTO notifications (account_id, user_id, type, title, body)
  SELECT '465fb4ce-33b6-4473-ad2c-42818772f587', u, 'promo_etecsa',
         'Nueva promocion de Etecsa detectada',
         format('%s-%s CUP x%s, del %s al %s. %s',
                p_min_cup, p_max_cup, p_multiplicador, p_desde, p_hasta,
                CASE WHEN v_precio IS NULL
                     THEN 'NO HAY PRECIO para ' || p_min_cup || ' CUP: hay que ponerlo antes de poder cotizar.'
                     ELSE 'Precio ' || v_precio || ' GYD. Confirmela para que el bot cotice solo.' END)
    FROM unnest(ARRAY['e3c7943d-b2fa-4c53-ae2f-406f1533ed47',
                      '5c4d16fd-1530-4023-8119-b58e04cc815f',
                      'ca797265-a1b3-43f7-9d9f-68c15d1f4780']::uuid[]) AS u;

  RETURN CASE WHEN v_precio IS NULL
              THEN 'detectada, PERO FALTA EL PRECIO para ' || p_min_cup || ' CUP'
              ELSE 'detectada, pendiente de confirmar' END;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] registrar promo fallo: %', SQLERRM;
  RETURN 'fallo: ' || SQLERRM;
END $$;


CREATE OR REPLACE FUNCTION cerebro_promo_confirmar(p_id uuid, p_quien text DEFAULT 'osmany')
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE promo_etecsa SET estado='confirmada', confirmada_at=now(), confirmada_por=p_quien
   WHERE id = p_id
  RETURNING 'confirmada: ' || min_cup || '-' || max_cup || ' CUP x' || multiplicador;
$$;


-- ---------------------------------------------------------------------
-- 6. Como llega al agente — SIN tocar el prompt ni el workflow
-- ---------------------------------------------------------------------
-- `cerebro_servicio_get('recargas')` añade la promo al texto de hechos y
-- baja `requiere_humano` a false cuando hay una utilizable. El agente no
-- cambia: solo recibe mejor informacion por la tool que ya llamaba.
--
-- (definicion aplicada: ver la funcion en la base; añade el bloque
--  CASE WHEN s.clave='recargas' ... sobre `hechos` y `requiere_humano`)
--
-- Tambien hubo que ampliar el CHECK de `notifications.type` con
-- 'promo_etecsa'. Comprobado antes en el codigo del CRM que
-- `TYPE_ICON[n.type] ?? Bell` tiene fallback, asi que un tipo nuevo no
-- rompe la pagina: sale con la campana generica. Conviene que Hermes le
-- ponga icono propio, que es una linea.


-- =====================================================================
-- COMO SE PROBO (9-ago-2026)
--
--   1. Sin promo: `requiere_humano=true` y el texto dice "HOY NO HAY
--      PROMOCION CONFIRMADA. No cotices recargas". Igual que antes.
--   2. Promo real cargada (600-1250 CUP x6, 13-16 ago, leida de
--      etecsa.cu): queda 'detectada' y avisa en el CRM.
--   3. Confirmarla NO la activa todavia: hoy es 9-ago y empieza el 13.
--      **El control de vigencia por fechas funciona.**
--   4. Con una promo vigente HOY y confirmada (bloque revertido):
--      `requiere_humano: true -> false` y el agente recibe
--      "PROMOCION VIGENTE HOY: se recarga el minimo de 600 CUP y el
--       cliente recibe x6. Precio para el cliente: 6200 GYD."
--
-- ESTADO AL CERRAR: la promo del 13 al 16 esta DETECTADA, pendiente de
-- que Osmany la confirme. El 13 empieza a ser vigente. Si para entonces
-- esta confirmada, el bot cotiza recargas solo por primera vez.
-- =====================================================================
