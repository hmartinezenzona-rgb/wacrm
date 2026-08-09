-- =====================================================================
-- 046 — Pipeline de Servicios y `service_type` en las operaciones
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- Es SOLO infraestructura. **No cambia ningun comportamiento**: nadie
-- crea deals en el pipeline nuevo todavia, y las 19 operaciones
-- existentes quedan como 'remesa'.
--
-- POR QUE AHORA Y NO CUANDO HAGA FALTA
--
--   `remittance_operations` se creo hoy mismo (migracion 040) y tiene 19
--   filas. Añadir `service_type` ahora es una columna con default; con
--   miles de filas y cinco flujos vivos seria migrar la tabla, las
--   funciones, los triggers y las cinco tools. Mismo criterio que se
--   aplico con `account_id`: es el momento mas barato que va a existir.
--
-- ROLLBACK
--   ALTER TABLE remittance_operations DROP COLUMN service_type;
--   DELETE FROM pipeline_stages WHERE pipeline_id =
--     (SELECT id FROM pipelines WHERE name='Servicios');
--   DELETE FROM pipelines WHERE name='Servicios';
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. El tipo de servicio en la operacion
-- ---------------------------------------------------------------------

ALTER TABLE remittance_operations
  ADD COLUMN IF NOT EXISTS service_type text NOT NULL DEFAULT 'remesa';

ALTER TABLE remittance_operations
  DROP CONSTRAINT IF EXISTS remittance_operations_service_chk;
ALTER TABLE remittance_operations
  ADD CONSTRAINT remittance_operations_service_chk CHECK (service_type IN
    ('remesa','combo','recarga','visa','traduccion','mexico'));

CREATE INDEX IF NOT EXISTS remittance_operations_service_idx
  ON remittance_operations (service_type, status);


-- ---------------------------------------------------------------------
-- 2. El pipeline
-- ---------------------------------------------------------------------
-- UN pipeline para los cinco servicios, no uno por servicio. Con ~19
-- operaciones a la semana, cinco pipelines es maquinaria por delante de
-- la demanda; el CRM ya filtra por titulo. Cuando alguno tenga volumen
-- propio, se separa.
--
--   Pipeline `Servicios` .......... 37f91872-6eb6-40d4-b8e6-1017053b9bf0
--     0. Solicitado ............... fc07d794-050b-4c84-b86f-4e0c0fd406b5
--     1. Pagado ................... 3d7fb431-445f-4bca-8647-f009eea0d27e
--     2. En proceso ............... 7ab184a6-ecb0-4461-96cf-e1077636ef05
--     3. Entregado ................ b8ad623b-b2a5-4e64-9eff-457e35815df0
--     4. Incidencia ............... 080541a0-b9d2-46ba-ac97-89ab2221c38b
--
-- (creado con el SQL que hay al final; los IDs quedan anotados porque
--  hacen falta para cualquier mapeo posterior, igual que los de remesas)


-- ---------------------------------------------------------------------
-- 3. LO QUE FALTA PARA QUE ESTO SE USE — leerlo antes de seguir
-- ---------------------------------------------------------------------
--
-- **Los triggers de la Fase 2 IGNORAN este pipeline.** Tanto
-- `cerebro_sync_operacion_desde_deal` como `cerebro_sync_benef_trigger`
-- empiezan con:
--
--     IF NEW.pipeline_id <> '78220927-...' THEN RETURN NULL; END IF;
--
-- Asi que hoy un deal en `Servicios` NO crea operacion ni beneficiarios.
-- Es lo correcto mientras no haya flujo, y es **lo primero que hay que
-- tocar** cuando lo haya.
--
-- **El enrutado del comprobante es el problema de fondo.** Hoy TODO
-- comprobante MMG entra por el flujo de remesas. Si un cliente paga un
-- combo y manda la captura, se registra como remesa. Comprobado el
-- 9-ago que **todavia no ha pasado** —los 6 deals sin beneficiario no
-- tienen relacion con servicios— pero solo porque el agente deriva los
-- pagos de combo a una persona antes de llegar ahi. Es contencion por
-- proceso, no por diseño.
--
-- El enrutado NO puede depender del modelo. Debe depender del estado: si
-- hay una operacion de servicio viva en la conversacion, el pago va ahi;
-- si no, es remesa. `cerebro_resolver_operacion()` ya hace esa
-- resolucion sin adivinar — habria que darle el `service_type`.
--
-- **Por donde empezar:** `traduccion` y `visa` son los unicos dos con
-- `requiere_humano = false`. Precio fijo, sin negociacion: el agente ya
-- puede cerrarlos solo. Combos, recargas y Mexico dependen de las 37
-- preguntas de `PREGUNTAS-OSMANY-servicios.md`.
-- =====================================================================


-- SQL de creacion del pipeline, idempotente:
--
-- WITH base AS (
--   SELECT user_id, account_id FROM pipelines
--    WHERE id='78220927-0745-45a8-ba08-a1b33734dbf1'
-- ), nuevo AS (
--   INSERT INTO pipelines (name, user_id, account_id)
--   SELECT 'Servicios', user_id, account_id FROM base
--    WHERE NOT EXISTS (SELECT 1 FROM pipelines WHERE name='Servicios')
--   RETURNING id
-- )
-- INSERT INTO pipeline_stages (pipeline_id, name, position)
-- SELECT n.id, e.nombre, e.pos FROM nuevo n
--   CROSS JOIN (VALUES ('Solicitado',0),('Pagado',1),('En proceso',2),
--                      ('Entregado',3),('Incidencia',4)) AS e(nombre,pos);
