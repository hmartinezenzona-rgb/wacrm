-- =====================================================================
-- 244 -- Saldo movil reaches the bot: catalogue row + the keyword stops routing to recargas
--
-- odd/tasks/cerebro-prompt-restructure.md (T2a). Owner 2026-10-18: the bot must be able to SELL and
-- SET every service, saldo movil included -- quote, answer, collect the data and fix the service.
-- Only the transfer stays with the admin, which the system already enforces by having no transfer
-- tool at all.
--
-- Saldo movil was never half-built: migration 223 models it completely as its own operation service
-- (remittance_operations_service_chk accepts 'saldo', one Cuban phone per operation, price and size
-- as cerebro_config data). What was missing is the BOT half, which 223's own header anticipated when
-- it called those values something for "the later bot": with no cerebro_servicios row,
-- consultar_servicio('saldo') returns nothing, so the bot cannot describe or quote it.
--
-- TWO CHANGES, and the second is the actual bug:
--   A. the 'saldo' catalogue row.
--   B. 'saldo' is REMOVED from the keywords of `recargas`. Migration 138 gave recargas
--      ARRAY['recarga','saldo','etecsa','cubacel'], so today every customer question about saldo is
--      routed to the Etecsa-promotion recharge service -- a different product, with a different
--      price, that does not exist outside a promotion. Adding the row without this would leave the
--      misrouting in place.
--
-- The price is DATA, not prose: `hechos` and `resumen` are composed at insert time FROM
-- cerebro_config (precio_saldo_gyd, saldo_unidad_cup), so the row cannot disagree with the
-- configured price on the day it ships. It is still a SNAPSHOT -- see the warning in
-- notas_internas, and contrast with efectivo_usd (137), whose 290 GYD/USD rate is typed into its
-- text and has to be hand-edited whenever it changes.
--
-- Idempotent: ON CONFLICT DO UPDATE, same shape as 137. No BEGIN/COMMIT.
-- =====================================================================

-- A. the catalogue row -------------------------------------------------
INSERT INTO cerebro_servicios (clave, nombre, activo, hechos, requiere_humano,
                               notas_internas, resumen, palabras_clave, actualizado)
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
  'odd/tasks/cerebro-prompt-restructure.md T2a, 2026-10-18. El servicio ya existia desde la 223 '
    'pero no tenia fila de catalogo, asi que consultar_servicio(''saldo'') no devolvia nada y el '
    'bot no podia ni describirlo ni cotizarlo. AVISO: el precio y el tamano de paquete de este '
    'texto son una FOTO de cerebro_config (precio_saldo_gyd, saldo_unidad_cup) en el momento de '
    'aplicar esta migracion. Si se cambian esos valores hay que regenerar esta fila, o el bot '
    'cotizara un precio viejo. Mismo riesgo que efectivo_usd (137), que lleva su tasa de 290 '
    'escrita a mano en el texto.',
  'Saldo movil a Cuba en paquetes de ' || u.valor || ' CUP por ' || p.precio
    || ' GYD cada uno, todo el ano, sin depender de promociones.',
  ARRAY['saldo', 'saldo movil', 'recargar saldo', 'poner saldo'],
  now()
  FROM (SELECT valor::numeric AS precio FROM cerebro_config WHERE clave = 'precio_saldo_gyd') p
  CROSS JOIN (SELECT valor FROM cerebro_config WHERE clave = 'saldo_unidad_cup') u
ON CONFLICT (clave) DO UPDATE SET
  nombre          = EXCLUDED.nombre,
  activo          = EXCLUDED.activo,
  hechos          = EXCLUDED.hechos,
  requiere_humano = EXCLUDED.requiere_humano,
  notas_internas  = EXCLUDED.notas_internas,
  resumen         = EXCLUDED.resumen,
  palabras_clave  = EXCLUDED.palabras_clave,
  actualizado     = now();

-- B. 'saldo' deja de enrutar a recargas -------------------------------
-- Se quita SOLO esa palabra; 'recarga', 'etecsa' y 'cubacel' siguen siendo de recargas.
UPDATE cerebro_servicios
   SET palabras_clave = array_remove(palabras_clave, 'saldo'),
       actualizado    = now()
 WHERE clave = 'recargas'
   AND 'saldo' = ANY(palabras_clave);
