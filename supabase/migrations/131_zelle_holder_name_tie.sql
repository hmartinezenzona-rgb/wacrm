-- =====================================================================
-- 131 — Zelle holder name: tied to its account, completed by the written name
--
-- The Cerebro accumulates the beneficiary across message bursts in
-- cerebro_beneficiario_parcial (node 'Merge beneficiario', COALESCE(new, old)).
-- Real errors found on 2026-09-28:
--   - "[Contacto] Nelson" then, 2 h later, "Nelson Tejo Perez": the stored name
--     stayed "Nelson" (aea25fc0);
--   - "[Contacto] Tata 12392695584", then another account +1 832 386 9000 with
--     no name: the pair became Tata + 8323869000, the name of one person on the
--     account of another (b0f3237c).
-- Rules approved by the user (2026-09-28):
--   - zelle_nombre_cuenta: the account the name came with (contact card, name +
--     number, vision). If the account changes and no new name comes, the node
--     drops the name instead of pairing it with the new account;
--   - cerebro_nombre_completa(full, label): a standalone full name that contains
--     every word of the stored label ("Nelson" → "Nelson Tejo Perez") replaces it.
-- Additive only: a new nullable column and a new pure function. Rows already
-- stored are untouched (their zelle_nombre_cuenta stays NULL = not tied, which
-- keeps today's behaviour for them).
--
-- ROLLBACK: ROLLBACK-131-zelle-holder-name-tie.sql
-- Guarded by pruebas/banco-merge-nombre.py (the node's real SQL) and
-- supabase/staging/assertions/zelle-holder-name.sql
-- =====================================================================

ALTER TABLE cerebro_beneficiario_parcial ADD COLUMN IF NOT EXISTS zelle_nombre_cuenta text;

COMMENT ON COLUMN cerebro_beneficiario_parcial.zelle_nombre_cuenta IS
  '131. The Zelle account (10 digits or lower-case e-mail) the stored name came with. NULL = the '
  'name came alone. When the account changes without a new name, the name is dropped.';

-- TRUE when p_completo has MORE words than p_etiqueta and contains every one of
-- them (case and accents ignored). "Nelson Tejo Perez" completes "Nelson";
-- "Jaime Rodriguez" does not complete "Tata".
CREATE OR REPLACE FUNCTION cerebro_nombre_completa(p_completo text, p_etiqueta text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  WITH a AS (SELECT array_remove(regexp_split_to_array(lower(translate(btrim(coalesce(p_completo, '')),
                     'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')), '\s+'), '') AS w),
       b AS (SELECT array_remove(regexp_split_to_array(lower(translate(btrim(coalesce(p_etiqueta, '')),
                     'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')), '\s+'), '') AS w)
  SELECT coalesce(cardinality(b.w) > 0 AND cardinality(a.w) > cardinality(b.w) AND b.w <@ a.w, false)
    FROM a, b
$$;

COMMENT ON FUNCTION cerebro_nombre_completa(text, text) IS
  '131. TRUE when a written full name completes a stored label (contains all its words, has more).';

REVOKE EXECUTE ON FUNCTION cerebro_nombre_completa(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_nombre_completa(text, text) TO service_role;

NOTIFY pgrst, 'reload schema';
