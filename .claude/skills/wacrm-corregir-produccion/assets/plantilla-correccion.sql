-- PLANTILLA de correccion de produccion. Copiar, rellenar los <...> y NO ejecutar tal cual.
-- Un bloque DO por correccion. Si el estado no es el esperado, RAISE aborta el bloque entero: nada queda aplicado.
-- Ejecutar solo con el go-ahead del dueno:
--   infra/db/correccion-produccion.sh <fichero.sql> --confirmar
-- Sin sentencias de esquema (DROP TABLE, TRUNCATE, DROP SCHEMA, ALTER TABLE ... DROP COLUMN): el script las rechaza.

DO $$
DECLARE
  v_op      uuid := '<OPERACION_UUID>';
  v_account uuid;
  v_antes   jsonb;
  v_despues jsonb;
BEGIN
  -- 1. Identidad de auditoria (local a la transaccion).
  PERFORM set_config('wacrm.origin', 'admin', true);
  PERFORM set_config('wacrm.actor', 'claude-code:owner-request', true);

  -- 2. Re-comprobar el estado esperado (valores que la investigacion vio). Si no coincide, RAISE.
  SELECT account_id,
         jsonb_build_object('quoted_destination_amount', quoted_destination_amount, 'status', status)
    INTO v_account, v_antes
    FROM remittance_operations
   WHERE id = v_op
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operacion % no existe', v_op;
  END IF;
  IF (v_antes->>'quoted_destination_amount')::numeric IS DISTINCT FROM <VALOR_ESPERADO_ANTES>::numeric THEN
    RAISE EXCEPTION 'estado inesperado en %: %', v_op, v_antes;
  END IF;

  -- 3. El cambio. Filas identificadas por id; nunca un UPDATE sin WHERE.
  UPDATE remittance_operations
     SET quoted_destination_amount = <NUEVO_VALOR>
   WHERE id = v_op;

  v_despues := jsonb_build_object('quoted_destination_amount', <NUEVO_VALOR>);

  -- 4. Auditoria: una fila por cada fila cambiada.
  INSERT INTO remittance_admin_audit
    (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES
    (v_account, 'remittance_operations', v_op, 'quoted_destination_amount', 'human_correction',
     'claude-code:owner-request', '<MOTIVO: palabras del dueno, AAAA-MM-DD>', v_antes, v_despues);
END $$;

-- 5. Verificacion: consulta aparte, despues del bloque. Debe devolver los valores nuevos.
SELECT id, quoted_destination_amount, status
  FROM remittance_operations
 WHERE id = '<OPERACION_UUID>';
