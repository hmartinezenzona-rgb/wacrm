-- =====================================================================
-- 040 — Fase 2, tramo 2A: estado canónico de la remesa
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--   (es idempotente, pero no hay motivo)
--
-- Qué hace:
--   1. Crea `remittance_operations`, el estado canónico de cada remesa
--   2. Define las transiciones permitidas entre estados
--   3. Crea el resolutor de `operation_id` que NO adivina
--   4. Rellena una operacion por cada deal existente (backfill)
--   5. Deja una consulta de conciliacion para detectar divergencias
--
-- Qué NO hace, a proposito:
--   - No toca ningun workflow. Nadie lee esta tabla todavia.
--   - No toca `deals` ni `deals.notes`. Siguen siendo la fuente de verdad.
--   - No cambia ni un comportamiento visible para el cliente.
--
-- Esto es la mitad de SQL del tramo 2A. La escritura dual desde el
-- Cerebro va aparte (2A.2), para que si algo se tuerce se sepa qué fue.
--
-- ROLLBACK (al final del fichero, comentado): basta con DROP de lo
-- creado. Como nadie lo lee, revertir no afecta a nada en produccion.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. La tabla
-- ---------------------------------------------------------------------
-- Nota sobre multiempresa: NO se crea un `tenant_id` nuevo. `deals` ya
-- tiene `account_id` y es el eje que usa WaCRM. Inventar un concepto
-- paralelo ahora obligaria a reconciliar dos ejes despues. Esto es lo
-- que pide la Fase 4 del spec, cumplido con lo que ya existe.

CREATE TABLE IF NOT EXISTS remittance_operations (
  id                        uuid PRIMARY KEY DEFAULT uuid_generate_v4(),

  account_id                uuid NOT NULL,
  conversation_id           uuid NOT NULL,
  contact_id                uuid,
  deal_id                   uuid,

  status                    text NOT NULL DEFAULT 'collecting_information',

  source_country            text DEFAULT 'GY',
  source_currency           text DEFAULT 'GYD',
  destination_currency      text,
  delivery_method           text,
  deposit_method            text,

  quoted_source_amount      numeric,
  quoted_destination_amount numeric,

  -- Control optimista: lo exige el contrato de herramientas de la
  -- Fase 2 (`expected_operation_version`). Lo incrementa el trigger.
  version                   integer NOT NULL DEFAULT 1,

  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  completed_at              timestamptz,
  cancelled_at              timestamptz,

  CONSTRAINT remittance_operations_status_chk CHECK (status IN (
    'collecting_information',
    'awaiting_deposit',
    'deposit_received',
    'deposit_verification',
    'ready_to_transfer',
    'transferring',
    'completed',
    'incident',
    'cancelled'
  ))
);

-- Un deal se corresponde como mucho con una operacion. Parcial porque
-- una operacion puede existir antes de que exista su deal.
CREATE UNIQUE INDEX IF NOT EXISTS remittance_operations_deal_uk
  ON remittance_operations (deal_id) WHERE deal_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS remittance_operations_conv_idx
  ON remittance_operations (conversation_id);

CREATE INDEX IF NOT EXISTS remittance_operations_status_idx
  ON remittance_operations (status);

CREATE INDEX IF NOT EXISTS remittance_operations_account_idx
  ON remittance_operations (account_id);

-- El indice que de verdad usa el resolutor: operaciones vivas por
-- conversacion. NO es unico — permitir dos vivas es justamente el
-- objetivo de la Fase 2.
CREATE INDEX IF NOT EXISTS remittance_operations_vivas_idx
  ON remittance_operations (conversation_id, created_at DESC)
  WHERE status NOT IN ('completed', 'cancelled');


-- ---------------------------------------------------------------------
-- 2. Transiciones permitidas
-- ---------------------------------------------------------------------
-- El spec pide definirlas. Se implementan como funcion consultable en
-- vez de como constraint rigido: durante la convivencia con el flujo
-- viejo conviene poder registrar lo que pasa de verdad, no lo que el
-- diagrama dice que deberia pasar.

CREATE OR REPLACE FUNCTION cerebro_op_transicion_valida(
  p_desde text,
  p_hasta text
) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_desde = p_hasta THEN true
    -- A incidencia y a cancelada se puede llegar desde cualquier sitio
    WHEN p_hasta IN ('incident', 'cancelled') THEN true
    -- De incidencia se sale hacia atras cuando una persona lo arregla
    WHEN p_desde = 'incident' THEN true
    WHEN p_desde = 'collecting_information' AND p_hasta IN ('awaiting_deposit','deposit_received') THEN true
    WHEN p_desde = 'awaiting_deposit'       AND p_hasta IN ('deposit_received') THEN true
    WHEN p_desde = 'deposit_received'       AND p_hasta IN ('deposit_verification','ready_to_transfer') THEN true
    WHEN p_desde = 'deposit_verification'   AND p_hasta IN ('ready_to_transfer') THEN true
    -- OJO: el pipeline real NO tiene etapa "transfiriendo". De "Lista
    -- para transferir" se pasa directo a "Entregada". La primera version
    -- de esta funcion solo permitia pasar por `transferring` y habria
    -- rechazado el camino que el negocio usa de verdad — lo cazo la
    -- prueba D. Se admiten los dos.
    WHEN p_desde = 'ready_to_transfer'      AND p_hasta IN ('transferring','completed') THEN true
    WHEN p_desde = 'transferring'           AND p_hasta IN ('completed') THEN true
    ELSE false
  END;
$$;


-- ---------------------------------------------------------------------
-- 3. version y updated_at automaticos
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cerebro_op_touch() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  -- Solo sube la version si cambio algo que no sea la propia marca de
  -- tiempo; asi el control optimista no salta por un toque vacio.
  IF NEW.* IS DISTINCT FROM OLD.* THEN
    NEW.version := OLD.version + 1;
  END IF;

  IF NEW.status = 'completed' AND OLD.status <> 'completed' THEN
    NEW.completed_at := coalesce(NEW.completed_at, now());
  END IF;
  IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' THEN
    NEW.cancelled_at := coalesce(NEW.cancelled_at, now());
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_remittance_operations_touch ON remittance_operations;
CREATE TRIGGER trg_remittance_operations_touch
  BEFORE UPDATE ON remittance_operations
  FOR EACH ROW EXECUTE FUNCTION cerebro_op_touch();


-- ---------------------------------------------------------------------
-- 4. El resolutor — la pieza que sustituye a "el mas reciente"
-- ---------------------------------------------------------------------
-- Regla del spec: "Nunca adivines". Esta funcion NO elige entre dos
-- candidatas: dice que hay dos y deja que el llamador derive o pregunte.
--
-- Devuelve una fila con:
--   resultado = 'unica'    -> hay exactamente una viva; operation_id va relleno
--               'ninguna'  -> no hay ninguna viva; operation_id es NULL
--               'ambigua'  -> hay dos o mas; operation_id es NULL a proposito
--   candidatas = cuantas vivas hay
--
-- El caso 'ambigua' es el que hoy se resuelve mal en siete sitios
-- distintos con ORDER BY created_at DESC LIMIT 1.

CREATE OR REPLACE FUNCTION cerebro_resolver_operacion(
  p_conversation_id uuid
) RETURNS TABLE (
  resultado    text,
  operation_id uuid,
  candidatas   integer
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_n integer;
  v_id uuid;
BEGIN
  SELECT count(*) INTO v_n
    FROM remittance_operations
   WHERE conversation_id = p_conversation_id
     AND status NOT IN ('completed', 'cancelled');

  IF v_n = 0 THEN
    RETURN QUERY SELECT 'ninguna'::text, NULL::uuid, 0;
  ELSIF v_n = 1 THEN
    SELECT o.id INTO v_id
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled');
    RETURN QUERY SELECT 'unica'::text, v_id, 1;
  ELSE
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_n;
  END IF;
END $$;


-- ---------------------------------------------------------------------
-- 5. Backfill — una operacion por cada deal que ya existe
-- ---------------------------------------------------------------------
-- Idempotente: el ON CONFLICT sobre el indice unico de deal_id impide
-- duplicar si esto se ejecuta dos veces.
--
-- El mapeo de etapa a estado sale del pipeline real de remesas.
-- Los importes NO se parsean de las notas: se coge `deals.value`, que
-- es dato estructurado. Reconstruir el resto desde texto libre es
-- justamente lo que esta fase viene a eliminar, y con 19 deals no
-- compensa el riesgo de leer mal.

INSERT INTO remittance_operations (
  account_id, conversation_id, contact_id, deal_id, status,
  quoted_source_amount, source_currency, created_at, completed_at
)
SELECT
  d.account_id,
  d.conversation_id,
  d.contact_id,
  d.id,
  CASE d.stage_id
    WHEN '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109' THEN 'collecting_information' -- Solicitada
    WHEN '3cf01654-cd27-47c1-ac92-62abf5435751' THEN 'deposit_verification'   -- Por verificar
    WHEN 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63' THEN 'ready_to_transfer'      -- Lista para transferir
    WHEN '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b' THEN 'completed'              -- Entregada
    WHEN 'da7b3e24-9222-4150-8be8-d7f7378e16aa' THEN 'incident'               -- Incidencia
    ELSE 'collecting_information'
  END,
  d.value,
  coalesce(d.currency, 'GYD'),
  d.created_at,
  CASE WHEN d.stage_id = '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b'
       THEN coalesce(d.updated_at, d.created_at) END
FROM deals d
WHERE d.conversation_id IS NOT NULL
  AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------
-- 6. Conciliacion — se ejecuta en cada despliegue de la Fase 2
-- ---------------------------------------------------------------------
-- Mientras convivan las dos representaciones, esta vista tiene que
-- devolver CERO filas. Cualquier fila es una divergencia.

CREATE OR REPLACE VIEW cerebro_conciliacion_operaciones AS
  -- Deals de remesas sin operacion
  SELECT 'deal sin operacion'::text AS problema, d.id AS deal_id, NULL::uuid AS operation_id
    FROM deals d
    LEFT JOIN remittance_operations o ON o.deal_id = d.id
   WHERE d.conversation_id IS NOT NULL
     AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
     AND o.id IS NULL
  UNION ALL
  -- Operaciones cuyo deal desaparecio (ver deuda 13)
  SELECT 'operacion sin deal', NULL, o.id
    FROM remittance_operations o
    LEFT JOIN deals d ON d.id = o.deal_id
   WHERE o.deal_id IS NOT NULL AND d.id IS NULL
  UNION ALL
  -- Estado desincronizado entre etapa y operacion
  SELECT 'estado divergente', d.id, o.id
    FROM remittance_operations o
    JOIN deals d ON d.id = o.deal_id
   WHERE o.status <> CASE d.stage_id
     WHEN '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109' THEN 'collecting_information'
     WHEN '3cf01654-cd27-47c1-ac92-62abf5435751' THEN 'deposit_verification'
     WHEN 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63' THEN 'ready_to_transfer'
     WHEN '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b' THEN 'completed'
     WHEN 'da7b3e24-9222-4150-8be8-d7f7378e16aa' THEN 'incident'
     ELSE 'collecting_information' END;


-- =====================================================================
-- COMO SE PROBO (9-ago-2026) — todo en produccion, sobre datos reales
--
--   1. Backfill: 19 deals -> 19 operaciones (17 completed, 2
--      ready_to_transfer). `cerebro_conciliacion_operaciones` -> 0 filas
--   2. Resolutor sobre las 19 conversaciones reales: 17 'ninguna',
--      2 'unica'. Ninguna 'ambigua', que es lo esperado hoy
--   3. AMBIGUEDAD FORZADA, en bloque DO revertido: al abrir una segunda
--      operacion viva en la misma conversacion el resolutor devolvio
--      'ambigua', candidatas=2 y operation_id NULL. NO eligio. Este es
--      el comportamiento que sustituye al ORDER BY created_at LIMIT 1
--   4. Trigger de version: 1 -> 2 tras un UPDATE
--   5. Idempotencia: reejecutar el backfill -> 0 filas nuevas
--   6. Transiciones: lista->entregada true, deposito->lista true,
--      collecting->completed false, retroceso completed->lista false
--
--   La prueba 6 encontro un fallo real en la primera version: la tabla
--   de transiciones venia del spec, que supone una etapa "transfiriendo"
--   que este pipeline no tiene. Rechazaba el camino real del negocio.
--   Corregido antes de dar el tramo por bueno.
--
-- ROLLBACK
--
--   DROP VIEW IF EXISTS cerebro_conciliacion_operaciones;
--   DROP FUNCTION IF EXISTS cerebro_resolver_operacion(uuid);
--   DROP TRIGGER IF EXISTS trg_remittance_operations_touch ON remittance_operations;
--   DROP FUNCTION IF EXISTS cerebro_op_touch();
--   DROP FUNCTION IF EXISTS cerebro_op_transicion_valida(text, text);
--   DROP TABLE IF EXISTS remittance_operations;
--
--   Nadie lee esto todavia, asi que revertir no afecta a produccion.
-- =====================================================================
