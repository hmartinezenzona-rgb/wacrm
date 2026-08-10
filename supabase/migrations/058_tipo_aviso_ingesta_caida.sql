-- 058 — Nuevo tipo de aviso: ingesta_caida
-- YA APLICADA EN PRODUCCION el 10-ago-2026. NO LA EJECUTES.
--
-- POR QUE
-- El 10-ago las dos credenciales de Gmail caducaron y la ingesta de correos de
-- MMG estuvo 4 horas parada SIN QUE SALTARA NINGUNA ALARMA: el Gmail Trigger de
-- n8n no genera ejecuciones cuando falla el sondeo, asi que el workflow sigue
-- activo y sin errores. Nueve depositos seguidos sin verificar y tres clientes
-- con 194.200 GYD esperando. Se descubrio mirando otra cosa.
-- Ver docs/negocio/18-dos-caidas-silenciosas.md
--
-- El vigilante nuevo (`Vigilante - ingesta de depositos MMG`, NiibUBRtOlOppmY4)
-- avisa EN EL CRM, que es el canal que no depende de la ventana de 24 h de
-- WhatsApp. Para eso necesita un tipo de aviso nuevo.
--
-- COMO SE DESCUBRIO QUE HACIA FALTA
-- Probando el vigilante con una credencial rota a proposito: detectaba la caida
-- pero el INSERT reventaba con notifications_type_check. Sin esa prueba, el
-- vigilante habria quedado desplegado detectando bien y sin poder avisar —
-- peor que no tenerlo, porque se daria por cubierto.

ALTER TABLE notifications DROP CONSTRAINT notifications_type_check;

ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type = ANY (ARRAY['conversation_assigned'::text,
                           'deal_incidencia'::text,
                           'mensaje_fallido'::text,
                           'promo_etecsa'::text,
                           'chat_atascado'::text,
                           'ingesta_caida'::text]));

-- COMPROBACION
-- SELECT pg_get_constraintdef(oid) FROM pg_constraint
--  WHERE conrelid='notifications'::regclass AND conname='notifications_type_check';

-- REVERSION
-- Volver a la lista de cinco tipos. Antes hay que borrar los avisos del tipo
-- nuevo o el ALTER fallara:
--   DELETE FROM notifications WHERE type='ingesta_caida';
--   ALTER TABLE notifications DROP CONSTRAINT notifications_type_check;
--   ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
--     CHECK (type = ANY (ARRAY['conversation_assigned'::text,'deal_incidencia'::text,
--                              'mensaje_fallido'::text,'promo_etecsa'::text,
--                              'chat_atascado'::text]));

-- PARA HERMES
-- `ingesta_caida` es un tipo nuevo. Si la UI del CRM pone icono o sonido por
-- tipo, este no lo tiene. Es de la familia de `deal_incidencia`: alguien tiene
-- que ir a mirarlo, y ademas es urgente — mientras dure, ningun deposito se
-- verifica solo.
