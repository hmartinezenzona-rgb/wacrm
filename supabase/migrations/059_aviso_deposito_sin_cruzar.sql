-- 059 — Tipo de aviso `deposito_sin_cruzar` y sus umbrales
-- YA APLICADA EN PRODUCCION el 10-ago-2026. NO LA EJECUTES.
--
-- POR QUE
-- El vigilante de la credencial (058) detecta que no se puede LEER el buzon,
-- pero no ve otras causas por las que un deposito no se cruza: que MMG deje de
-- mandar correos, que se rompa el filtro del asunto, un fallo de parseo, o una
-- referencia mal leida por la vision. El 10-ago un comprobante quedo sin cruzar
-- porque la vision leyo el TransID 20397544023399 y el correo decia
-- 20397544023299 — UN DIGITO.
--
-- Este vigilante mira la CONSECUENCIA: un deal en "Por verificar" cuyo TransID
-- no esta en el libro pasados N minutos = hay un cliente esperando.
-- Workflow: `Vigilante - depositos sin cruzar` (bTwsEJsmoAzsuOxm), cada 10 min.
--
-- CALIBRACION, medida antes de elegir el umbral
-- El correo de MMG llega casi siempre ANTES que el comprobante del cliente:
-- desfases tipicos de -1 a -17 minutos sobre 23 casos del 8 al 10-ago. Solo uno
-- llego despues. Por eso 15 minutos es una anomalia de verdad y no un retraso
-- normal. Con ese umbral, en el historico habria avisado de los 9 depositos de
-- la caida del 10-ago y de 3 referencias mal leidas del 8-ago: todas legitimas.

ALTER TABLE notifications DROP CONSTRAINT notifications_type_check;

ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type = ANY (ARRAY['conversation_assigned'::text,
                           'deal_incidencia'::text,
                           'mensaje_fallido'::text,
                           'promo_etecsa'::text,
                           'chat_atascado'::text,
                           'ingesta_caida'::text,
                           'deposito_sin_cruzar'::text]));

-- Umbrales: se tocan sin desplegar nada.
INSERT INTO cerebro_config (clave, valor) VALUES
  ('sin_cruzar_minutos','15'),      -- cuanto espera antes de avisar
  ('sin_cruzar_repetir_min','120')  -- cada cuanto repite el aviso del mismo deal
ON CONFLICT (clave) DO NOTHING;

-- AJUSTES EN CALIENTE
--   UPDATE cerebro_config SET valor='20'  WHERE clave='sin_cruzar_minutos';
--   UPDATE cerebro_config SET valor='180' WHERE clave='sin_cruzar_repetir_min';

-- COMPROBACION
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conrelid='notifications'::regclass AND conname='notifications_type_check';
--   SELECT * FROM cerebro_config WHERE clave LIKE 'sin_cruzar%';

-- REVERSION
-- Desactivar el workflow bTwsEJsmoAzsuOxm. El tipo y la config pueden quedarse.

-- PARA HERMES
-- `deposito_sin_cruzar` es un tipo nuevo. Es de la familia de `deal_incidencia`
-- —alguien tiene que ir a mirarlo— y ademas hay un cliente esperando su dinero.
