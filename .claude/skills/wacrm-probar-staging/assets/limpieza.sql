-- Limpieza de UNA conversacion PRUEBA en STAGING. Solo staging.
-- Sin BEGIN/COMMIT: ejecutar con psql -1 (una transaccion; si algo falla, no se borra nada).
--   -v conv=<uuid de la conversacion>
-- Antes de borrar, muestra el contacto, operaciones y beneficiarios. Aborta si el contacto no empieza por PRUEBA.
-- Orden: auditoria -> expediente (funding_case; sus depositos vinculados cascada) -> depositos (desvincular los reales,
-- borrar los PRUEBA) -> objetivos -> filas de calculadora y consumos CUP -> beneficiarios -> operaciones
-- (mixed_group_id a NULL antes: FK sobre si misma) -> mensajes -> conversacion -> contacto.

SELECT set_config('pr.conv', :'conv', true)\g /dev/null

DO $lp$
DECLARE
  v_conv   uuid := current_setting('pr.conv')::uuid;
  v_ct     uuid; v_name text; v_phone text; v_prefix text;
  v_ops    uuid[]; v_bens uuid[];
BEGIN
  SELECT ct.id, ct.name, ct.phone INTO v_ct, v_name, v_phone
    FROM conversations cv JOIN contacts ct ON ct.id = cv.contact_id
   WHERE cv.id = v_conv;
  IF v_ct IS NULL THEN RAISE EXCEPTION 'limpieza: la conversacion % no existe', v_conv; END IF;
  IF v_name IS NULL OR v_name NOT LIKE 'PRUEBA%' THEN
    RAISE EXCEPTION 'limpieza: el contacto "%" no empieza por PRUEBA; no se borra nada', v_name; END IF;

  SELECT COALESCE(array_agg(id), '{}') INTO v_ops FROM remittance_operations WHERE conversation_id = v_conv;
  SELECT COALESCE(array_agg(id), '{}') INTO v_bens FROM remittance_beneficiaries WHERE operation_id = ANY (v_ops);
  v_prefix := 'PRUEBA ' || v_phone || '%';

  RAISE NOTICE 'limpieza: contacto "%" telefono % operaciones % beneficiarios % depositos PRUEBA % expedientes %',
    v_name, v_phone, cardinality(v_ops), cardinality(v_bens),
    (SELECT count(*) FROM depositos_mmg WHERE asunto LIKE v_prefix),
    (SELECT count(*) FROM funding_case WHERE conversation_id = v_conv);

  DELETE FROM remittance_admin_audit WHERE row_id = ANY (v_ops) OR row_id = ANY (v_bens);
  -- The funding case must go before the deposits: case_deposits references them with ON DELETE RESTRICT,
  -- and deleting the case cascades its links, allocations and movements.
  DELETE FROM funding_case WHERE conversation_id = v_conv;
  -- real deposits that were consumed by a fixture operation are released, not deleted
  UPDATE depositos_mmg SET operation_id = NULL, consumido_en = NULL
   WHERE operation_id = ANY (v_ops) AND asunto NOT LIKE v_prefix;
  DELETE FROM depositos_mmg WHERE asunto LIKE v_prefix;
  DELETE FROM cerebro_objetivo_envio WHERE conversation_id = v_conv OR operation_id = ANY (v_ops);
  DELETE FROM remittance_calculator_entries WHERE operation_id = ANY (v_ops);
  DELETE FROM cup_lot_consumptions WHERE operation_id = ANY (v_ops);
  UPDATE remittance_operations SET mixed_group_id = NULL WHERE id = ANY (v_ops);
  DELETE FROM remittance_beneficiaries WHERE id = ANY (v_bens);
  DELETE FROM remittance_operations WHERE id = ANY (v_ops);
  DELETE FROM messages WHERE conversation_id = v_conv;
  DELETE FROM conversations WHERE id = v_conv;
  DELETE FROM contacts WHERE id = v_ct;

  RAISE NOTICE 'limpieza ok: borrados contacto, conversacion, % operaciones, % beneficiarios',
    cardinality(v_ops), cardinality(v_bens);
END
$lp$;
