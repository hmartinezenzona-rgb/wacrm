-- =====================================================================
-- 128 — Store what the Cerebro's vision read from every image
--
-- The vision step reads beneficiaries (Cuban card + phone, Zelle name +
-- number/email) and receipts from photos, but that reading only lived inside
-- the n8n execution (kept ~36 h). Consequences found on 2026-09-27:
--   - 4 of the 5 real Cuban-card repartos arrived as PHOTOS, so the automatic
--     reparto (127) could not see them;
--   - the same image (same hash) was read once as 'otro' and once with the
--     full Zelle data, and nothing recorded it, so vision quality could not be
--     measured.
--
-- cerebro_lecturas_vision keeps every reading, raw (`datos`) plus the fields
-- the rest of the system reads. The Cerebro's new node 'Guardar lecturas
-- vision' calls cerebro_guardar_lecturas_vision once per burst. The function
-- never raises (a bad element is skipped), so storing a reading can never
-- stop the bot. It is idempotent per (execution, message, image), so a retry
-- stores nothing twice.
-- Server-side only: RLS on, no policies, no grants to anon/authenticated.
--
-- ROLLBACK: ROLLBACK-128-vision-readings.sql (keeps the data unless told otherwise)
-- Guarded by supabase/staging/assertions/vision-lecturas.sql
-- =====================================================================

CREATE TABLE IF NOT EXISTS cerebro_lecturas_vision (
  id              bigserial PRIMARY KEY,
  creado          timestamptz NOT NULL DEFAULT now(),
  conversation_id uuid,
  execution_id    text,
  wamid           text,
  hash_imagen     text,
  tipo            text,
  numero_tarjeta  text,
  celular         text,
  nombre          text,
  celular_us      text,
  correo          text,
  monto           numeric,
  moneda          text,
  referencia      text,
  estado          text,
  leida_girada    boolean,
  giro_elegido    integer,
  datos           jsonb NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS cerebro_lecturas_vision_unica
  ON cerebro_lecturas_vision (coalesce(execution_id, ''), coalesce(wamid, ''), coalesce(hash_imagen, ''));
CREATE INDEX IF NOT EXISTS cerebro_lecturas_vision_conv ON cerebro_lecturas_vision (conversation_id, creado);
CREATE INDEX IF NOT EXISTS cerebro_lecturas_vision_wamid ON cerebro_lecturas_vision (wamid);

ALTER TABLE cerebro_lecturas_vision ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON cerebro_lecturas_vision FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE cerebro_lecturas_vision_id_seq FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON cerebro_lecturas_vision TO service_role;

COMMENT ON TABLE cerebro_lecturas_vision IS
  '128. Every reading the Cerebro''s vision made of a customer image (raw in '
  'datos). Feeds the automatic reparto for photos and measures vision quality.';

CREATE OR REPLACE FUNCTION cerebro_guardar_lecturas_vision(p_conversation_id uuid, p_execution_id text, p_lecturas jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item jsonb;
  v_n    integer := 0;
  v_k    integer;
  v_monto numeric;
BEGIN
  IF p_lecturas IS NULL OR jsonb_typeof(p_lecturas) <> 'array' THEN RETURN 0; END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_lecturas) LOOP
    BEGIN
      IF jsonb_typeof(v_item) <> 'object' THEN CONTINUE; END IF;
      BEGIN
        v_monto := nullif(v_item->>'monto', '')::numeric;
      EXCEPTION WHEN OTHERS THEN v_monto := NULL;
      END;
      INSERT INTO cerebro_lecturas_vision (
        conversation_id, execution_id, wamid, hash_imagen, tipo,
        numero_tarjeta, celular, nombre, celular_us, correo,
        monto, moneda, referencia, estado, leida_girada, giro_elegido, datos)
      VALUES (
        p_conversation_id, p_execution_id, v_item->>'wamid', v_item->>'hash_imagen', v_item->>'tipo',
        nullif(regexp_replace(coalesce(v_item->>'numero_tarjeta', v_item->>'tarjeta', ''), '\D', '', 'g'), ''),
        nullif(regexp_replace(coalesce(v_item->>'celular', ''), '\D', '', 'g'), ''),
        nullif(btrim(coalesce(v_item->>'nombre', '')), ''),
        nullif(btrim(coalesce(v_item->>'celular_us', '')), ''),
        nullif(lower(btrim(coalesce(v_item->>'correo', ''))), ''),
        v_monto, v_item->>'moneda', v_item->>'referencia', v_item->>'estado',
        CASE WHEN v_item->>'leida_girada' IN ('true', 'false') THEN (v_item->>'leida_girada')::boolean END,
        CASE WHEN v_item->>'giro_elegido' ~ '^-?[0-9]+$' THEN (v_item->>'giro_elegido')::integer END,
        v_item)
      ON CONFLICT DO NOTHING;
      GET DIAGNOSTICS v_k = ROW_COUNT;
      v_n := v_n + v_k;
    EXCEPTION WHEN OTHERS THEN
      -- Storing a reading must never stop the bot: skip this element.
      RAISE WARNING '[cerebro] lectura de vision no guardada: %', SQLERRM;
    END;
  END LOOP;
  RETURN v_n;
END $$;

COMMENT ON FUNCTION cerebro_guardar_lecturas_vision(uuid, text, jsonb) IS
  '128. Stores a burst of vision readings; never raises; idempotent per '
  '(execution, wamid, image hash).';

REVOKE EXECUTE ON FUNCTION cerebro_guardar_lecturas_vision(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_guardar_lecturas_vision(uuid, text, jsonb) TO service_role;

NOTIFY pgrst, 'reload schema';
