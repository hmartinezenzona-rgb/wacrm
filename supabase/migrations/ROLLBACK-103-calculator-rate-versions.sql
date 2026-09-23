-- =====================================================================
-- ROLLBACK-103 — reverts 103_calculator_rate_versions.sql
--
-- Drops the rate-version write path, the current-rates helper, the
-- append-only trigger and the table itself.
--
-- DESTRUCTIVE: every appended rate version is lost. That history is the
-- only record of what rate each remesa was priced at, so 104 (which
-- stamps `rate_version_id` onto ledger entries) must be rolled back
-- FIRST — otherwise its foreign key blocks this drop, or, once that key
-- is gone, its entries point at versions nobody can read any more.
--
-- 095's `remittance_calculator_documents` rate columns were never touched
-- by 103, so the /calculadora screen keeps working after this runs.
-- =====================================================================

DROP FUNCTION IF EXISTS crm_set_calculator_rates(uuid, jsonb, uuid);
DROP FUNCTION IF EXISTS calculator_rates_vigentes(uuid);

DROP TRIGGER IF EXISTS calculator_rate_versions_append_only ON calculator_rate_versions;
DROP FUNCTION IF EXISTS calculator_rate_versions_append_only();

DROP TABLE IF EXISTS calculator_rate_versions;
