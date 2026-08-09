-- =====================================================================
-- 042 — Fase 2, tramo 2C.1: beneficiarios estructurados y auditados
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- Saca los beneficiarios del texto libre de `deals.notes` a una tabla,
-- conservando el historial de correcciones.
--
-- LO QUE ESTA MIGRACION NO ARREGLA — leelo antes de darla por buena:
--
--   La deuda 14 (`registrar_beneficiario_zelle` escribiendo el destino
--   de una operacion en otra) SIGUE VIVA. Las tools del Cerebro no se
--   han tocado: siguen cogiendo el deal abierto mas reciente.
--
--   Lo que cambia es que ahora la contaminacion queda REGISTRADA y es
--   DETECTABLE, en vez de perderse dentro de un campo de texto. El
--   arreglo de verdad es 2C.2: que las tools usen
--   `cerebro_resolver_operacion()` y no escriban si devuelve 'ambigua'.
--
-- ROLLBACK
--   DROP TRIGGER IF EXISTS trg_sync_benef_desde_deal ON deals;
--   DROP TABLE IF EXISTS remittance_beneficiaries;
--   (las funciones pueden quedarse; sin trigger no las llama nadie)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. La tabla
-- ---------------------------------------------------------------------
-- `status` distingue el dato vigente del historico. Una correccion NO
-- borra: marca el anterior como 'reemplazado'. Eso es lo que pide el
-- spec ("las correcciones deben reemplazar el dato vigente sin borrar
-- auditoria") y ademas es como ya se comportan las notas, que son
-- append-only.

CREATE TABLE IF NOT EXISTS remittance_beneficiaries (
  id               uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  operation_id     uuid NOT NULL REFERENCES remittance_operations(id) ON DELETE CASCADE,
  beneficiary_type text NOT NULL,
  name             text,
  card_number      text,
  phone            text,
  zelle_account    text,
  delivery_method  text,
  amount           numeric,
  currency         text,
  position         integer NOT NULL DEFAULT 1,
  status           text NOT NULL DEFAULT 'vigente',
  source           text NOT NULL DEFAULT 'notes_parse',
  block_index      integer,
  confirmed_at     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  replaced_at      timestamptz,
  CONSTRAINT rb_type_chk CHECK (beneficiary_type IN
    ('cuban_card','zelle','clasica','tropical','multiple_distribution')),
  CONSTRAINT rb_status_chk CHECK (status IN ('vigente','reemplazado'))
);

CREATE INDEX IF NOT EXISTS rb_operation_idx ON remittance_beneficiaries (operation_id);
CREATE INDEX IF NOT EXISTS rb_vigente_idx ON remittance_beneficiaries (operation_id)
  WHERE status = 'vigente';

-- Clave de idempotencia: un bloque de notas produce siempre las mismas
-- filas, se sincronice una vez o cien.
CREATE UNIQUE INDEX IF NOT EXISTS rb_unico_por_bloque
  ON remittance_beneficiaries (operation_id, block_index, position);


-- ---------------------------------------------------------------------
-- 2. El parser
-- ---------------------------------------------------------------------
-- Los formatos NO se dedujeron de los datos: se leyeron de las querys
-- de las tools que los escriben (`gestionar_beneficiario`,
-- `registrar_beneficiario_zelle`, `registrar_reparto_multiple`,
-- `Registrar beneficiario auto`). Encabezados reconocidos:
--
--   BENEFICIARIO
--   BENEFICIARIO (nombre)
--   BENEFICIARIO (auto)
--   BENEFICIARIO ACTUALIZADO - reemplaza al anterior
--   BENEFICIARIO ACTUALIZADO (auto) - reemplaza al anterior
--   BENEFICIARIO ZELLE  [ACTUALIZADO - ...]
--   REPARTO [ACTUALIZADO] ENTRE VARIOS BENEFICIARIOS
--
-- Los bloques se separan con "\n---\n" y las notas son append-only, asi
-- que el indice de bloque da el orden cronologico gratis.

CREATE OR REPLACE FUNCTION cerebro_parsear_beneficiarios(p_notes text)
RETURNS TABLE (
  block_index integer, tipo text, nombre text,
  tarjeta text, celular text, cuenta_zelle text,
  monto numeric, moneda text, posicion integer
)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_bloques text[];
  v_b text;
  v_i integer := 0;
  v_fila text[];
BEGIN
  v_bloques := regexp_split_to_array(coalesce(p_notes,''), E'\n---\n');

  FOREACH v_b IN ARRAY v_bloques LOOP
    v_i := v_i + 1;

    IF v_b ~ '^REPARTO' THEN
      FOR v_fila IN
        SELECT regexp_matches(v_b, '([0-9]+)\) Tarjeta: ([0-9]+) \| Celular: ([0-9]+) \| Recibe: ([0-9]+) CUP', 'g')
      LOOP
        block_index := v_i; tipo := 'multiple_distribution'; nombre := NULL;
        tarjeta := v_fila[2]; celular := v_fila[3]; cuenta_zelle := NULL;
        monto := v_fila[4]::numeric; moneda := 'CUP'; posicion := v_fila[1]::integer;
        RETURN NEXT;
      END LOOP;

    ELSIF v_b ~ '^BENEFICIARIO ZELLE' THEN
      block_index := v_i; tipo := 'zelle';
      nombre := substring(v_b from 'Nombre: ([^\n]*)');
      tarjeta := NULL; celular := NULL;
      cuenta_zelle := substring(v_b from 'Cuenta Zelle: ([^\n]*)');
      monto := NULL; moneda := NULL; posicion := 1;
      IF cuenta_zelle IS NOT NULL THEN RETURN NEXT; END IF;

    ELSIF v_b ~ '^BENEFICIARIO' THEN
      block_index := v_i; tipo := 'cuban_card';
      nombre := substring(v_b from '^BENEFICIARIO[^\n(]*\(([^)]*)\)');
      tarjeta := substring(v_b from 'Tarjeta: ([0-9]+)');
      celular := substring(v_b from 'Celular: ([0-9]+)');
      cuenta_zelle := NULL; monto := NULL; moneda := NULL; posicion := 1;
      -- "(auto)" es la procedencia del dato, no el nombre de una persona
      IF nombre = 'auto' THEN nombre := NULL; END IF;
      IF tarjeta IS NOT NULL THEN RETURN NEXT; END IF;
    END IF;
  END LOOP;
END $$;


-- ---------------------------------------------------------------------
-- 3. Sincronizador
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cerebro_sync_beneficiarios(p_deal_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_op uuid; v_notes text; v_max int; v_nuevos int := 0;
BEGIN
  SELECT o.id, d.notes INTO v_op, v_notes
    FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE d.id = p_deal_id;

  IF v_op IS NULL THEN RETURN 0; END IF;

  WITH p AS (SELECT * FROM cerebro_parsear_beneficiarios(v_notes))
  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone,
    zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular,
         p.cuenta_zelle, p.monto, p.moneda, p.posicion, p.block_index,
         'notes_parse', 'vigente'
    FROM p
  ON CONFLICT (operation_id, block_index, position) DO NOTHING;

  GET DIAGNOSTICS v_nuevos = ROW_COUNT;

  SELECT max(block_index) INTO v_max
    FROM remittance_beneficiaries WHERE operation_id = v_op;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_max AND status <> 'reemplazado';

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND block_index = v_max AND status <> 'vigente';

  RETURN v_nuevos;
END $$;


-- ---------------------------------------------------------------------
-- 4. Trigger
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cerebro_sync_benef_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_usd text; v_tipo text;
BEGIN
  IF NEW.pipeline_id <> '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid
     OR NEW.conversation_id IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM cerebro_sync_beneficiarios(NEW.id);

  -- "ENTREGA EN USD: Clasica|Tropical" no es un beneficiario: es COMO se
  -- entrega. Va a la operacion, no a esta tabla.
  SELECT (regexp_matches(NEW.notes, 'ENTREGA EN USD: (Clasica|Tropical)', 'g'))[1]
    INTO v_usd ORDER BY 1 DESC LIMIT 1;

  SELECT b.beneficiary_type INTO v_tipo
    FROM remittance_beneficiaries b
    JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.deal_id = NEW.id AND b.status = 'vigente' LIMIT 1;

  UPDATE remittance_operations o
     SET delivery_method = coalesce(lower(v_usd), v_tipo, o.delivery_method)
   WHERE o.deal_id = NEW.id
     AND o.delivery_method IS DISTINCT FROM coalesce(lower(v_usd), v_tipo, o.delivery_method);

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- Misma regla que la 041: esto no puede tumbar el flujo del dinero.
  RAISE WARNING '[cerebro] sync beneficiarios fallo para deal % : %', NEW.id, SQLERRM;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_sync_benef_desde_deal ON deals;
CREATE TRIGGER trg_sync_benef_desde_deal
  AFTER INSERT OR UPDATE OF notes ON deals
  FOR EACH ROW EXECUTE FUNCTION cerebro_sync_benef_trigger();


-- ---------------------------------------------------------------------
-- 5. Backfill
-- ---------------------------------------------------------------------
--   SELECT sum(cerebro_sync_beneficiarios(d.id)) FROM deals d
--    WHERE d.pipeline_id='78220927-0745-45a8-ba08-a1b33734dbf1';
--
-- Resultado el 9-ago: 13 beneficiarios (8 zelle + 5 tarjeta cubana),
-- que son exactamente los 13 deals con bloque BENEFICIARIO en notas.


-- =====================================================================
-- COMO SE PROBO (9-ago-2026), en bloques DO revertidos
--
--   Parser contra los 19 deals REALES antes de escribir nada:
--     13 de 13 leidos, 8 zelle + 5 cuban_card. Cuadra con el conteo
--     de bloques en notas. El deal con "CORREGIDO A MANO" (la foto
--     girada) se ignora bien: no es un bloque de beneficiario.
--
--   A. CORRECCION de beneficiario -> el nuevo queda 'vigente', el
--      anterior 'reemplazado', y NADA SE BORRA (2 filas).
--      Historia resultante: "0025:reemplazado, 6666:vigente"
--   C. Reparto entre tres -> 3 filas con sus posiciones y montos
--      (1=10000 2=20000 3=30000)
--   D. "ENTREGA EN USD: Tropical" -> delivery_method='tropical' en la
--      operacion, no en la tabla de beneficiarios
--   E. Idempotencia: dos sincronizaciones extra -> 0 duplicados
--
-- ROLLBACK
--   DROP TRIGGER IF EXISTS trg_sync_benef_desde_deal ON deals;
--   DROP TABLE IF EXISTS remittance_beneficiaries;
-- =====================================================================
