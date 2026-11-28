-- =====================================================================
-- ROLLBACK-113 — reverts 113_tasas_derives_from_the_calculator.sql
--
-- Restores `tasas` as a real, writable TABLE with its original columns
-- and defaults, and re-populates it from `tasas_historico` (the archive
-- 113 copied the original rows into before dropping the table).
--
-- `tasas_historico` itself is NOT dropped here: it is the durable
-- historical rate record 113 exists to preserve, and destroying it on a
-- rollback would be exactly the data loss 113's own header explains this
-- table avoids. If a genuinely fresh table is ever wanted, that is a
-- separate, deliberate decision — not an automatic side effect of
-- reverting this migration.
--
-- After this runs, `tasas` is writable again but nothing writes to it —
-- same as before 113 (see 113's header: zero functions, triggers or
-- foreign keys touch it). Restoring writability does not restore any
-- writer; there was none to restore.
-- =====================================================================

DROP VIEW IF EXISTS tasas;

CREATE TABLE tasas (
  fecha          date        NOT NULL DEFAULT CURRENT_DATE,
  tasa_cup       numeric     NOT NULL,
  fuente         text        NOT NULL DEFAULT 'whatsapp',
  actualizada_at timestamptz NOT NULL DEFAULT now(),
  moneda         text        NOT NULL DEFAULT 'usd',
  PRIMARY KEY (fecha, moneda)
);

-- Same lockdown as the original table: RLS enabled, no policies, so only
-- postgres/service_role (BYPASSRLS) ever see a row despite the default
-- schema-wide ACL nominally granting anon/authenticated arwdDxtm too.
ALTER TABLE tasas ENABLE ROW LEVEL SECURITY;

INSERT INTO tasas (fecha, tasa_cup, fuente, actualizada_at, moneda)
SELECT fecha, tasa_cup, fuente, actualizada_at, moneda FROM tasas_historico
ON CONFLICT (fecha, moneda) DO NOTHING;

NOTIFY pgrst, 'reload schema';
