-- =====================================================================
-- 138 — Service catalog from one place (cerebro_servicios)
--
-- WHY
--   WHICH services exist was hand-written in 3 places (mapped in
--   odd/tasks/service-catalog-single-source.md, task S1): the
--   `Agente Remesas` prompt's "## OTROS SERVICIOS" list and its
--   service->keyword map, the `consultar_servicio` $fromAI description
--   (an enumeration of claves), and the "Hay TRES/CUATRO vias" count in
--   "## VIA USD" for the efectivo_usd case (137, cash-usd-service-info.md).
--   Adding, editing or switching off a service meant touching the prompt
--   or the tool description by hand, with no guarantee all 2 copies (list
--   + keyword map) stayed in sync, and no way for the bot to ever forget
--   an active service or invent an inactive one.
--
-- WHAT
--   `cerebro_servicios` gains two columns:
--     palabras_clave text[] — the keywords that route a customer message
--       to that service, taken VERBATIM from the keyword map already
--       written in "## OTROS SERVICIOS" (the only source for them: no
--       keyword is invented here).
--     resumen text — one line per service, derived ONLY from that row's
--       existing `nombre`/`hechos` (the same facts the bot already
--       recites via consultar_servicio -> cerebro_servicio_get). No new
--       fact enters the table through this migration.
--   A backfill fills both for the 6 rows that exist today (combos,
--   recargas, visa, traduccion, mexico, efectivo_usd).
--   `cerebro_catalogo_servicios()` returns ONE text block, compact
--   (target < 400 tokens for ~7 services), with the ACTIVE services only
--   (`WHERE activo`), ready to inject into the per-turn context the same
--   way `cerebro_horario()` already does for business hours (see the
--   Cerebro staging/prod deploy, S4, not tracked here). Format:
--     "- <clave>: <resumen> [<palabras_clave, comma-joined>]" per line,
--   which is also the exact format `evals/casos/casos-catalogo-servicios.json`
--   (S2) mocks in `esperado._contexto.catalogo_servicios`, so the eval
--   harness measures the same shape production will inject.
--   `cerebro_servicio_get()` (049/122) is UNCHANGED: it still reads
--   `hechos` for the per-service detail; the catalog only carries the
--   short listing, never prices/conditions.
--
-- OUT OF SCOPE (see the doc)
--   A panel page to edit services. The Decisor's `recarga_en_curso`
--   keyword check and `pide_mlc` (MLC is not a `cerebro_servicios` row)
--   are mapped in S1 and left untouched: neither enumerates the full
--   service list, so neither is a hand-written catalog copy.
--
-- IDEMPOTENT: ADD COLUMN IF NOT EXISTS; the backfill UPDATEs by clave
-- and is safe to re-run; the function is CREATE OR REPLACE.
-- ROLLBACK: ROLLBACK-138-service-catalog.sql
-- Guarded by supabase/staging/assertions/service-catalog.sql
-- =====================================================================

ALTER TABLE cerebro_servicios
  ADD COLUMN IF NOT EXISTS palabras_clave text[],
  ADD COLUMN IF NOT EXISTS resumen text;

-- Backfill: resumen derived only from nombre/hechos of each row (049/137);
-- palabras_clave copied verbatim from the prompt's "## OTROS SERVICIOS"
-- keyword map (contrato/prompt-sistema.txt, section OTROS SERVICIOS).
UPDATE cerebro_servicios SET
  resumen = 'Envio de combos de comida a Cuba, a medida segun disponibilidad, minimo 25,000 GYD, envio incluido.',
  palabras_clave = ARRAY['combo','comida','mandar comida','paquete']
WHERE clave = 'combos';

UPDATE cerebro_servicios SET
  resumen = 'Recargas telefonicas a Cuba sobre la promocion de Etecsa vigente; sin promo no hay recargas.',
  palabras_clave = ARRAY['recarga','saldo','etecsa','cubacel']
WHERE clave = 'recargas';

UPDATE cerebro_servicios SET
  resumen = 'Extension de visa en Guyana: sube la aplicacion online, 4,000 GYD, pasaporte vigente.',
  palabras_clave = ARRAY['visa','extension de visa','inmigracion']
WHERE clave = 'visa';

UPDATE cerebro_servicios SET
  resumen = 'Traduccion oficial de documentos, 5,000 GYD por hoja (una cara), 24 horas.',
  palabras_clave = ARRAY['traducir','traduccion','documento','hoja']
WHERE clave = 'traduccion';

UPDATE cerebro_servicios SET
  resumen = 'Envio de dinero a Mexico por MMG, tasa 260 GYD/USD, minimo 13,000 GYD (50 USD).',
  palabras_clave = ARRAY['mexico','clabe','coppel','bbva']
WHERE clave = 'mexico';

UPDATE cerebro_servicios SET
  resumen = 'Entrega de dolares en efectivo en Cuba, tasa propia 290 GYD/USD, minimo 100 USD.',
  palabras_clave = ARRAY['efectivo','cash','dolares en mano','fisico']
WHERE clave = 'efectivo_usd';

-- Any row this migration does not know about (added after this file was
-- written, or missing the two new columns for any other reason) gets a
-- safe, honest fallback instead of silently NULL: the catalog line still
-- reads (nombre, no keywords), and the keyword-only route simply falls
-- through to a human, matching "not in the catalog behaves like it does
-- not exist" for palabras_clave until someone fills the real keywords.
UPDATE cerebro_servicios
   SET resumen = COALESCE(resumen, nombre),
       palabras_clave = COALESCE(palabras_clave, ARRAY[]::text[])
 WHERE resumen IS NULL OR palabras_clave IS NULL;

ALTER TABLE cerebro_servicios
  ALTER COLUMN palabras_clave SET DEFAULT ARRAY[]::text[],
  ALTER COLUMN palabras_clave SET NOT NULL,
  ALTER COLUMN resumen SET NOT NULL;

CREATE OR REPLACE FUNCTION cerebro_catalogo_servicios()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT 'CATALOGO DE SERVICIOS (ademas de remesas). Detalles, precios y '
         || 'condiciones SOLO con consultar_servicio(clave). Si un servicio '
         || 'no esta en esta lista, no existe: ofrece un operador.'
         || E'\n' || string_agg(
              format('- %s: %s [%s]', s.clave, s.resumen,
                     array_to_string(s.palabras_clave, ', ')),
              E'\n' ORDER BY s.nombre)
    FROM cerebro_servicios s
   WHERE s.activo;
$$;

COMMENT ON FUNCTION cerebro_catalogo_servicios() IS
  '138. Compact catalog of ACTIVE cerebro_servicios rows (clave, resumen, '
  'palabras_clave), one line each, ready to inject into the per-turn '
  'context the same way cerebro_horario() feeds business hours. Target '
  '< 400 tokens for ~7 services. Details/prices stay in cerebro_servicio_get().';
REVOKE EXECUTE ON FUNCTION cerebro_catalogo_servicios() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_catalogo_servicios() TO service_role;

-- =====================================================================
-- COMO SE PROBO (staging, 2026-09-28)
--
--   SELECT clave, resumen, palabras_clave FROM cerebro_servicios ORDER BY clave;
--   -> las 6 filas existentes, ambas columnas no nulas.
--   SELECT cerebro_catalogo_servicios();
--   -> un bloque de texto con las 6 lineas "- clave: resumen [palabras]",
--      ~<TOKENS> tokens aprox (ver el informe de la tarea S3/S4).
--   Assertions: supabase/staging/assertions/service-catalog.sql, RED -> GREEN.
-- =====================================================================
