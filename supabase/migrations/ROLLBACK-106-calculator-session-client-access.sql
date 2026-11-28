-- =====================================================================
-- ROLLBACK-106 — reverts 106_calculator_session_client_access.sql
--
-- Restores 095's service-role-only lockdown on the two calculator tables
-- and 103's inherited default privileges, and drops the document RPC.
--
-- AFTER RUNNING THIS, `/api/calculadora` MUST be back on a service-role
-- client, or the calculator screen stops loading: with the policies and
-- grants gone, a session client can read nothing. Roll the application
-- back together with this migration, never on its own.
-- =====================================================================

DROP FUNCTION IF EXISTS crm_guardar_documento_calculadora(uuid, text, text);

DROP POLICY IF EXISTS remittance_calculator_entries_select   ON remittance_calculator_entries;
DROP POLICY IF EXISTS remittance_calculator_documents_select ON remittance_calculator_documents;

REVOKE ALL ON remittance_calculator_entries   FROM anon, authenticated;
REVOKE ALL ON remittance_calculator_documents FROM anon, authenticated;

-- 103 shipped with Supabase's default privileges in place; restore them so
-- the rollback leaves exactly what was there before 106 ran.
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON calculator_rate_versions TO anon, authenticated;
