-- =====================================================================
-- Assertion for migration 195 (an ID card is the recipient's only when the names match). Self-reverting: one DO block
-- that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/remesa-closing-and-cash.md. Owner, 2026-10-03: an ID whose name is not the cash recipient's is NOT stored
-- until the right one arrives. Vision reads names imperfectly ("FRENE VERA ANABEL" for "Anabel Frenes Vera"), so the
-- match ignores case, accents and order and accepts one-letter differences; it needs 2 matching words of the recipient's
-- name (or its only word).
-- =====================================================================
DO $$
DECLARE v_case record;
BEGIN
  FOR v_case IN SELECT * FROM (VALUES
      ('FRENE VERA ANABEL',        'Anabel Frenes Vera', true,  'order, case, one letter'),
      ('Anabel Frene Vera',        'Anabel Frenes Vera', true,  'one letter missing'),
      ('MARLENE PEREZ GARCIA',     'Marlene Pérez',      true,  'accent and an extra surname'),
      ('ANABEL FRENE VERA',        'Marlene Pérez',      false, 'another person'),
      ('JOSE PEREZ GARCIA',        'Ana Pérez',          false, 'only a shared surname'),
      ('YUSLEIDY',                 'Yusleidy',           true,  'a single name'),
      ('',                         'Marlene Pérez',      false, 'nothing read'))
    AS t(carnet, recipient, expected, label)
  LOOP
    IF cerebro_nombre_coincide(v_case.carnet, v_case.recipient) IS DISTINCT FROM v_case.expected THEN
      RAISE EXCEPTION 'case "%": % vs % must be %', v_case.label, v_case.carnet, v_case.recipient, v_case.expected;
    END IF;
  END LOOP;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
