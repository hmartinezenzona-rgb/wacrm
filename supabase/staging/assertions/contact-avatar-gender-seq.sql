-- =====================================================================
-- Assertion for migration 263 (contacts.avatar_gender + avatar_seq). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Fixtures build their own account and contacts. Run it as:
-- BEGIN; \i contact-avatar-gender-seq.sql; ROLLBACK;
--
-- Cases:
--   1. crm_avatar_genero reads the first name: dictionary (incl. Cuban names), suffix rules, accents, case,
--      emoji / empty / NULL -> 'n'.
--   2. New contacts get the next 1-based number inside their (account, gender) group.
--   3. Renaming: 'n' -> a known gender takes the next number of that group; a known gender keeps gender and number.
--   4. Every existing contact was backfilled and no (account, gender, number) repeats (unique index exists).
-- =====================================================================
DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_acc  uuid;
  v_hash text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_got  text;
  v_f1 uuid; v_f2 uuid; v_m1 uuid; v_n1 uuid; v_n2 uuid;
  v_r record;
  v_case record;
BEGIN
  -- 1. gender from the first name
  FOR v_case IN SELECT * FROM (VALUES
      ('Yaniel Castro', 'm'), ('Mariela Fonseca', 'f'), ('Yuleisy', 'f'), ('Osmany', 'm'), ('Luis Proenza', 'm'),
      ('Yanelis', 'f'), ('Dayron', 'm'), ('Carmen', 'f'), ('MARÍA José', 'f'), ('José María', 'm'),
      ('Yoandry', 'm'), ('Leidy', 'f'), ('Raúl', 'm'), ('Rolando', 'm'), ('Dayana', 'f'), ('Alexis', 'm'),
      ('Yasmany', 'm'), ('Ernesto', 'm'), ('Niurka', 'f'), ('Isabel', 'f'), ('Noel', 'm'), ('Ruth', 'f'),
      ('  ana  ', 'f'), ('😊💕', 'n'), ('', 'n'), ('Cliente', 'n'), ('Mi amor', 'n'), ('Remesas Express', 'n'),
      ('+53 5555', 'n'), ('Aime', 'f'), ('Julie', 'f'), ('Osmani', 'm'), ('Josem Pérez', 'm'),
      ('Oscarbenitezsanchez', 'm'), ('Jorge', 'm'), ('Felipe', 'm'), ('James', 'm'), ('Betty', 'f'), ('tv', 'n')) AS t(nombre, esperado)
  LOOP
    v_got := crm_avatar_genero(v_case.nombre);
    IF v_got IS DISTINCT FROM v_case.esperado THEN
      RAISE EXCEPTION 'case 1: crm_avatar_genero(%) = %, expected %', quote_literal(v_case.nombre), v_got, v_case.esperado; END IF;
  END LOOP;
  IF crm_avatar_genero(NULL) IS DISTINCT FROM 'n' THEN RAISE EXCEPTION 'case 1: NULL must be n'; END IF;

  -- fixture account
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'av-' || v_user || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'avatar account', v_user) RETURNING id INTO v_acc;

  -- 2. per-group numbering
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990026301', 'Yuleisy Pérez') RETURNING id INTO v_f1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990026302', 'Osmany Ruiz') RETURNING id INTO v_m1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990026303', 'Dayana Gil') RETURNING id INTO v_f2;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990026304', '💕') RETURNING id INTO v_n1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990026305', NULL) RETURNING id INTO v_n2;
  FOR v_r IN SELECT c.id, c.avatar_gender, c.avatar_seq FROM contacts c WHERE c.account_id = v_acc LOOP
    IF (v_r.id = v_f1 AND (v_r.avatar_gender, v_r.avatar_seq) IS DISTINCT FROM ('f'::text, 1))
       OR (v_r.id = v_f2 AND (v_r.avatar_gender, v_r.avatar_seq) IS DISTINCT FROM ('f'::text, 2))
       OR (v_r.id = v_m1 AND (v_r.avatar_gender, v_r.avatar_seq) IS DISTINCT FROM ('m'::text, 1))
       OR (v_r.id = v_n1 AND (v_r.avatar_gender, v_r.avatar_seq) IS DISTINCT FROM ('n'::text, 1))
       OR (v_r.id = v_n2 AND (v_r.avatar_gender, v_r.avatar_seq) IS DISTINCT FROM ('n'::text, 2)) THEN
      RAISE EXCEPTION 'case 2: unexpected numbering %', to_jsonb(v_r); END IF;
  END LOOP;

  -- 3. renames
  UPDATE contacts SET name = 'Rolando Díaz' WHERE id = v_n1;
  SELECT avatar_gender, avatar_seq INTO v_r FROM contacts WHERE id = v_n1;
  IF (v_r.avatar_gender, v_r.avatar_seq) IS DISTINCT FROM ('m'::text, 2) THEN
    RAISE EXCEPTION 'case 3: n -> m must take the next masculine number, got %', to_jsonb(v_r); END IF;
  UPDATE contacts SET name = 'Yuleisy P. (mamá)' WHERE id = v_f1;
  SELECT avatar_gender, avatar_seq INTO v_r FROM contacts WHERE id = v_f1;
  IF (v_r.avatar_gender, v_r.avatar_seq) IS DISTINCT FROM ('f'::text, 1) THEN
    RAISE EXCEPTION 'case 3: a known gender keeps its number, got %', to_jsonb(v_r); END IF;
  UPDATE contacts SET name = 'Ernesto' WHERE id = v_f2;
  SELECT avatar_gender, avatar_seq INTO v_r FROM contacts WHERE id = v_f2;
  IF (v_r.avatar_gender, v_r.avatar_seq) IS DISTINCT FROM ('f'::text, 2) THEN
    RAISE EXCEPTION 'case 3: f -> m rename keeps the avatar (stable), got %', to_jsonb(v_r); END IF;
  UPDATE contacts SET phone = '5990026399' WHERE id = v_n2;
  SELECT avatar_gender, avatar_seq INTO v_r FROM contacts WHERE id = v_n2;
  IF (v_r.avatar_gender, v_r.avatar_seq) IS DISTINCT FROM ('n'::text, 2) THEN
    RAISE EXCEPTION 'case 3: an update that is not a rename changes nothing, got %', to_jsonb(v_r); END IF;

  -- 4. backfill and uniqueness
  IF EXISTS (SELECT 1 FROM contacts WHERE avatar_gender IS NULL OR avatar_seq IS NULL) THEN
    RAISE EXCEPTION 'case 4: every contact must have avatar_gender and avatar_seq'; END IF;
  IF EXISTS (SELECT 1 FROM contacts GROUP BY account_id, avatar_gender, avatar_seq HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'case 4: an (account, gender, number) repeats'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'contacts'
                  AND indexdef ILIKE '%UNIQUE%account_id, avatar_gender, avatar_seq%') THEN
    RAISE EXCEPTION 'case 4: the unique index on (account_id, avatar_gender, avatar_seq) is missing'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
