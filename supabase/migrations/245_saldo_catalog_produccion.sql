-- =====================================================================
-- 245 -- The saldo movil catalogue row for a catalogue WITHOUT migration 138's columns
--
-- Why this exists instead of just applying 244 to production.
--
-- 244 writes `resumen` and `palabras_clave`. Those two columns are created by
-- 138_service_catalog.sql, which is on STAGING and was never applied to PRODUCTION. Verified
-- 2026-10-19 on production (hqztotshnlzaiziwjyzh): `cerebro_servicios` is
--   clave, nombre, activo, hechos, enlace, requiere_humano, notas_internas, actualizado
-- while staging has those plus `palabras_clave` and `resumen`. `cerebro_servicio_get` on production
-- returns (nombre, hechos, enlace, requiere_humano, notas_internas) — no resumen either.
-- So 244 cannot be applied there: it would fail on two missing columns.
--
-- This ALSO corrects the diagnosis recorded in odd/tasks/cerebro-prompt-restructure.md T2a. Part B
-- of 244 ("'saldo' stops routing to recargas") fixes a STAGING bug: on production there are no DB
-- keywords at all, so service routing is done by the keyword table inside the PROMPT, and the
-- saldo-to-recargas misrouting lives there. The restructured prompt already routes
-- 'saldo' -> consultar_servicio('saldo'), so part B has no production counterpart and is omitted
-- here on purpose, not forgotten.
--
-- What is left is part A, the row itself, which is what makes consultar_servicio('saldo') able to
-- describe and quote the service at all. Same composition as 244: the price and the package size
-- are read from cerebro_config at insert time rather than typed, so the row cannot disagree with
-- the configured price on the day it ships. It is still a SNAPSHOT — see notas_internas.
--
-- Aligning production with 138 is a separate, larger job and is NOT done here; see
-- odd/tasks/align-staging-with-production.md. Doing it inside this change would drag the whole
-- keyword-routing mechanism into production for the sake of a single row.
--
-- Idempotent: ON CONFLICT DO UPDATE. No BEGIN/COMMIT.
-- =====================================================================

INSERT INTO cerebro_servicios (clave, nombre, activo, hechos, requiere_humano,
                               notas_internas, actualizado)
SELECT
  'saldo',
  'Saldo movil a Cuba',
  true,
  'Saldo movil para un telefono de Cuba. Se vende en paquetes fijos: ' || p.precio || ' GYD por '
    || 'cada paquete de ' || u.valor || ' CUP de saldo. Se pueden comprar varios paquetes para el '
    || 'mismo numero. NO es una recarga de promocion de Etecsa: el saldo movil se vende todo el '
    || 'ano, no depende de ninguna promocion, y tiene su propio precio. Solo hace falta el numero '
    || 'de Cuba, y es UN solo numero por pedido. El deposito se hace por MMG, igual que las demas '
    || 'vias. PROHIBIDO ofrecer rebajas, descuentos o precios especiales. Si el cliente pide '
    || 'rebaja, di la tarifa fija y que cualquier rebaja la trata una persona del equipo. El '
    || 'asistente TOMA el pedido: cotiza, pide el numero de Cuba y la captura del deposito; la '
    || 'recarga del saldo la hace una persona del equipo.',
  false,                      -- el bot lo vende y lo fija (dueno 2026-10-18)
  'odd/tasks/cerebro-prompt-restructure.md T2a. Gemela de la 244, adaptada al esquema de '
    'PRODUCCION, que no tiene las columnas resumen ni palabras_clave porque la 138 nunca se aplico '
    'alli. La parte B de la 244 (quitar ''saldo'' de las keywords de recargas) NO tiene equivalente '
    'aqui: en produccion el enrutado de servicios lo hace la tabla de palabras del PROMPT, y el '
    'prompt reestructurado ya manda ''saldo'' a consultar_servicio(''saldo''). '
    'AVISO: el precio y el tamano de paquete de este texto son una FOTO de cerebro_config '
    '(precio_saldo_gyd, saldo_unidad_cup) al aplicar esta migracion. Si se cambian esos valores hay '
    'que regenerar esta fila, o el bot cotizara un precio viejo.',
  now()
  FROM (SELECT valor::numeric AS precio FROM cerebro_config WHERE clave = 'precio_saldo_gyd') p
  CROSS JOIN (SELECT valor FROM cerebro_config WHERE clave = 'saldo_unidad_cup') u
ON CONFLICT (clave) DO UPDATE SET
  nombre          = EXCLUDED.nombre,
  activo          = EXCLUDED.activo,
  hechos          = EXCLUDED.hechos,
  requiere_humano = EXCLUDED.requiere_humano,
  notas_internas  = EXCLUDED.notas_internas,
  actualizado     = now();
