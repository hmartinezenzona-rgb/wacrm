-- check-reseller-identity.sql — task 2.1 (human-run, READ-ONLY, staging or production)
--
-- Pre-apply report for the reseller identity switch (395_reseller_identity.sql).
-- It answers "who changes reseller status on the day of the switch?" before any
-- migration runs. Four labelled result sets:
--
--   A. Active allow-list phones with no matching contact.
--      These stop being resellers when the bot moves from the allow-list to
--      the tag and no contact carries the tag for them.
--   B. Contacts that already carry a "Revendedor" tag but whose phone is NOT on
--      the active allow-list. These start being resellers for the bot.
--   C. Preview of the 395 backfill: contacts that will receive the tag and
--      accounts where a new "Revendedor" tag will be created.
--   D. Tag names close to "Revendedor" that the exact rule will NOT match
--      (plural, accents, typos). They are listed so the owner can spot tag
--      spellings that would leave a contact outside the reseller set.
--
-- CRITICAL: this file inlines the tag-name predicate
-- `lower(btrim(name)) = 'revendedor'` and the account-scoped tag join. It MUST
-- NOT call the 395 helpers (`reseller_tag_name_matches`,
-- `reseller_contact_is_tagged`), because it has to run on production BEFORE
-- 395 exists.
--
-- Privacy: only phones, account ids and tag names are printed. Contact names
-- and any other customer text are never selected.
--
-- HOW TO RUN (staging, from the repo root):
--   source infra/db/lib-migracion.sh && psql_staging < supabase/staging/check-reseller-identity.sql
-- HOW TO RUN (production): the owner pastes this whole file into the
--   production SQL editor and executes it as one script.
--
-- The script opens a READ ONLY transaction and always ROLLBACKs, so it cannot
-- write anything even if a query were wrong.

BEGIN;
SET TRANSACTION READ ONLY;

-- ===========================================================================
-- A. Active allow-list phones with no matching contact (stop being resellers)
-- ===========================================================================
SELECT format('A_count: %s', count(*)) AS reseller_report
  FROM cerebro_revendedores r
 WHERE r.activo
   AND NOT EXISTS (
     SELECT 1 FROM contacts c WHERE c.phone = r.phone
   );

SELECT format('A_phone: %s', r.phone) AS reseller_report
  FROM cerebro_revendedores r
 WHERE r.activo
   AND NOT EXISTS (
     SELECT 1 FROM contacts c WHERE c.phone = r.phone
   )
 ORDER BY r.phone;

-- ===========================================================================
-- B. Contacts tagged "Revendedor" that are NOT on the active allow-list
--    (become resellers for the bot)
-- ===========================================================================
SELECT format('B_count: %s', count(*)) AS reseller_report
  FROM (
    SELECT DISTINCT c.id
      FROM contacts c
      JOIN contact_tags ct ON ct.contact_id = c.id
      JOIN tags t          ON t.id = ct.tag_id AND t.account_id = c.account_id
     WHERE lower(btrim(t.name)) = 'revendedor'
       AND NOT EXISTS (
         SELECT 1 FROM cerebro_revendedores r
          WHERE r.activo AND r.phone = c.phone
       )
  ) tagged_not_allowlisted;

SELECT format('B_phone: %s', c.phone) AS reseller_report
  FROM contacts c
  JOIN contact_tags ct ON ct.contact_id = c.id
  JOIN tags t          ON t.id = ct.tag_id AND t.account_id = c.account_id
 WHERE lower(btrim(t.name)) = 'revendedor'
   AND NOT EXISTS (
     SELECT 1 FROM cerebro_revendedores r
      WHERE r.activo AND r.phone = c.phone
   )
 GROUP BY c.id, c.phone
 ORDER BY c.phone;

-- ===========================================================================
-- C. Preview of the 395 backfill
--    C1: contacts that will receive the tag (active allow-list phone, no tag).
--    C2: accounts where a new "Revendedor" tag will be created.
-- ===========================================================================
SELECT format('C_contact_count: %s', count(*)) AS reseller_report
  FROM (
    SELECT DISTINCT c.id
      FROM contacts c
      JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
     WHERE NOT EXISTS (
       SELECT 1
         FROM contact_tags ct
         JOIN tags t ON t.id = ct.tag_id
        WHERE ct.contact_id = c.id
          AND t.account_id = c.account_id
          AND lower(btrim(t.name)) = 'revendedor'
     )
  ) contacts_to_tag;

SELECT format('C_contact_phone: %s', c.phone) AS reseller_report
  FROM contacts c
  JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
 WHERE NOT EXISTS (
   SELECT 1
     FROM contact_tags ct
     JOIN tags t ON t.id = ct.tag_id
    WHERE ct.contact_id = c.id
      AND t.account_id = c.account_id
      AND lower(btrim(t.name)) = 'revendedor'
 )
 GROUP BY c.id, c.phone
 ORDER BY c.phone;

SELECT format('C_account_count: %s', count(*)) AS reseller_report
  FROM (
    SELECT DISTINCT c.account_id
      FROM contacts c
      JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
     WHERE NOT EXISTS (
       SELECT 1 FROM tags t
        WHERE t.account_id = c.account_id
          AND lower(btrim(t.name)) = 'revendedor'
     )
  ) accounts_to_create_tag;

SELECT format('C_account: %s', c.account_id) AS reseller_report
  FROM contacts c
  JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
 WHERE NOT EXISTS (
   SELECT 1 FROM tags t
    WHERE t.account_id = c.account_id
      AND lower(btrim(t.name)) = 'revendedor'
 )
 GROUP BY c.account_id
 ORDER BY c.account_id;

-- ===========================================================================
-- D. Near-miss tag names the exact rule will NOT match
-- ===========================================================================
SELECT format('D_count: %s', count(*)) AS reseller_report
  FROM (
    SELECT DISTINCT t.name
      FROM tags t
     WHERE t.name ILIKE '%revend%'
       AND lower(btrim(t.name)) <> 'revendedor'
  ) near_miss;

SELECT format('D_tag_name: %s', t.name) AS reseller_report
  FROM tags t
 WHERE t.name ILIKE '%revend%'
   AND lower(btrim(t.name)) <> 'revendedor'
 GROUP BY t.name
 ORDER BY t.name;

ROLLBACK;
