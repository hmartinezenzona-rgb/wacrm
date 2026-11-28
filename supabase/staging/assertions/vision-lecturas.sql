-- =====================================================================
-- Assertion for migration 128 (cerebro_lecturas_vision + cerebro_guardar_lecturas_vision).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- Items have the exact shape 'Parsear vision' emits (execution 248563, real).
-- =====================================================================
DO $$
DECLARE
  v_conv uuid; v_n int; v_r record;
  v_items CONSTANT jsonb := '[
    {"tipo":"cuenta_zelle","nombre":"Niorkis Hernandez","celular_us":"(602) 723-6103","correo":null,
     "hash_imagen":"6517006eb5d625b429a207647d374cebff7d81a1ed45b2f860b856a35a884b89","comp_id":null,
     "wamid":"wamid.TEST128A","leida_girada":false,"giro_elegido":0,"arbitro":"ninguna esta en el libro"},
    {"tipo":"tarjeta_cubana","numero_tarjeta":"9205 0699 9046 2359","celular":"56678919","monto":"30000",
     "hash_imagen":"aa00","wamid":"wamid.TEST128B","leida_girada":true,"giro_elegido":90},
    {"tipo":"comprobante","monto":15000,"moneda":"GYD","estado":"EXITOSA","referencia":"20401623619989",
     "hash_imagen":"bb00","comp_id":"COMP-bb00","wamid":"wamid.TEST128C","leida_girada":false,"giro_elegido":0},
    {"tipo":"otro","descripcion":"Pantalla de confirmación de envío de dinero.","monto":"no es un numero",
     "hash_imagen":"cc00","wamid":"wamid.TEST128D","leida_girada":false,"giro_elegido":0}]';
BEGIN
  SELECT id INTO v_conv FROM conversations LIMIT 1;

  -- 1. Every reading of the burst is stored, with its fields in columns.
  v_n := cerebro_guardar_lecturas_vision(v_conv, 'exec-test-128', v_items);
  IF v_n <> 4 THEN RAISE EXCEPTION 'case 1: expected 4 readings stored, got %', v_n; END IF;
  SELECT * INTO v_r FROM cerebro_lecturas_vision WHERE wamid = 'wamid.TEST128A';
  IF v_r.tipo <> 'cuenta_zelle' OR v_r.nombre <> 'Niorkis Hernandez' OR v_r.celular_us <> '(602) 723-6103'
     OR v_r.conversation_id <> v_conv OR v_r.execution_id <> 'exec-test-128' THEN
    RAISE EXCEPTION 'case 1: Zelle reading not stored as expected: %', row_to_json(v_r);
  END IF;
  SELECT * INTO v_r FROM cerebro_lecturas_vision WHERE wamid = 'wamid.TEST128B';
  IF v_r.numero_tarjeta <> '9205069990462359' OR v_r.celular <> '56678919' OR v_r.monto <> 30000 OR NOT v_r.leida_girada THEN
    RAISE EXCEPTION 'case 1: card reading not stored as expected: %', row_to_json(v_r);
  END IF;
  RAISE NOTICE 'PASS 1: a burst of readings (Zelle, card, receipt, other) is stored with its fields';

  -- 2. A value that is not a number never breaks the save: the field stays NULL.
  SELECT * INTO v_r FROM cerebro_lecturas_vision WHERE wamid = 'wamid.TEST128D';
  IF v_r.monto IS NOT NULL OR v_r.datos->>'descripcion' IS NULL THEN
    RAISE EXCEPTION 'case 2: bad amount should be NULL and the raw reading kept: %', row_to_json(v_r);
  END IF;
  RAISE NOTICE 'PASS 2: a malformed field is stored as NULL, the raw reading is kept';

  -- 3. A retry of the same execution stores nothing twice.
  v_n := cerebro_guardar_lecturas_vision(v_conv, 'exec-test-128', v_items);
  SELECT count(*) INTO v_r FROM cerebro_lecturas_vision WHERE execution_id = 'exec-test-128';
  IF v_n <> 0 OR (SELECT count(*) FROM cerebro_lecturas_vision WHERE execution_id = 'exec-test-128') <> 4 THEN
    RAISE EXCEPTION 'case 3: a retry must not duplicate readings (stored %)', v_n;
  END IF;
  RAISE NOTICE 'PASS 3: retrying the same execution is idempotent';

  -- 4. Garbage input never raises: 0 stored.
  v_n := cerebro_guardar_lecturas_vision(v_conv, 'exec-test-128b', '{"no":"array"}');
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 4: non-array input should store 0, got %', v_n; END IF;
  v_n := cerebro_guardar_lecturas_vision(v_conv, 'exec-test-128b', NULL);
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 4: NULL input should store 0, got %', v_n; END IF;
  RAISE NOTICE 'PASS 4: invalid input stores nothing and never raises';

  -- 5. Only the server side can read them.
  IF has_table_privilege('anon', 'cerebro_lecturas_vision', 'SELECT')
     OR has_table_privilege('authenticated', 'cerebro_lecturas_vision', 'SELECT') THEN
    RAISE EXCEPTION 'case 5: anon/authenticated must not read vision readings';
  END IF;
  RAISE NOTICE 'PASS 5: vision readings are not exposed to anon/authenticated';
END $$;

-- Convention: reaching this point means every case above passed.
DO $$ BEGIN RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'; END $$;
