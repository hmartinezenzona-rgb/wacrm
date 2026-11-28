-- =====================================================================
-- ROLLBACK 147 — remove the panel-action marker
--
-- Drops the column. Every panel-action send since this migration was
-- applied becomes indistinguishable from a human send again — the
-- B2.2 bug returns. The app-side skip and the Cerebro `humano_reciente`
-- exclusion must be reverted alongside this, or they will error/no-op
-- against a column that no longer exists.
-- =====================================================================

ALTER TABLE messages
  DROP COLUMN IF EXISTS is_panel_action;
