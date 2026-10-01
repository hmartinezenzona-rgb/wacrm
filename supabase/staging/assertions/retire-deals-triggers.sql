-- retire-deals-triggers.sql — self-reverting assertion for
-- 172_retire_deals_triggers_and_fk.sql (WU9)
--
-- Proves the two things that decide whether 6.4's `DROP TABLE` can ever run:
-- the foreign key from `depositos_mmg` is gone, and exactly the seven inert
-- triggers were retired while the two that still matter survived.
--
-- The single most important check is the last one. `update_updated_at_column`
-- is shared by eleven tables besides `deals`; if this migration took it out,
-- eleven unrelated tables would silently stop stamping `updated_at`. That is
-- the failure this assertion exists to catch.
--
-- RED (before 172): 9 triggers on `deals`, 1 FK to `deals`.
-- GREEN (after 172): 2 triggers (`set_updated_at`, `trg_sync_z_benef_desde_deal`),
--   0 FK, 12 attachments of the shared function.
--
-- MUST run inside an already-open transaction, or with the savepoint pair
-- below, and must never COMMIT. Never run against production.
-- No fixtures needed — this checks catalog state, not row data.

SAVEPOINT retire_deals_triggers;

DO $$
DECLARE
  v_triggers integer;
  v_fk       integer;
  v_shared   integer;
  v_deal_id  integer;
  v_fail     integer := 0;
BEGIN
  SELECT count(*) INTO v_triggers
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname = 'deals' AND NOT t.tgisinternal;

  IF v_triggers <> 2 THEN
    RAISE WARNING 'FAIL: % triggers remain on deals, expected 2', v_triggers;
    v_fail := v_fail + 1;
  ELSE
    RAISE NOTICE 'PASS: only set_updated_at and trg_sync_z_benef_desde_deal remain on deals';
  END IF;

  -- The behavioural trigger must still be there: WU6d has not repointed the
  -- `ENTREGA EN USD` transport yet, and it writes remittance_operations.
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'deals'
      AND t.tgname = 'trg_sync_z_benef_desde_deal' AND NOT t.tgisinternal
  ) THEN
    RAISE WARNING 'FAIL: trg_sync_z_benef_desde_deal was dropped — WU6d has not landed yet';
    v_fail := v_fail + 1;
  ELSE
    RAISE NOTICE 'PASS: trg_sync_z_benef_desde_deal is intact (WU6d dependency preserved)';
  END IF;

  SELECT count(*) INTO v_fk
  FROM pg_constraint con
  JOIN pg_class ref ON ref.oid = con.confrelid
  JOIN pg_namespace rn ON rn.oid = ref.relnamespace
  WHERE con.contype = 'f' AND rn.nspname = 'public' AND ref.relname = 'deals';

  IF v_fk <> 0 THEN
    RAISE WARNING 'FAIL: % foreign key(s) still reference deals', v_fk;
    v_fail := v_fail + 1;
  ELSE
    RAISE NOTICE 'PASS: no foreign key references deals';
  END IF;

  -- The column must survive: cerebro_objetivo_envio / cerebro_saldo_envio
  -- are still keyed by it.
  SELECT count(*) INTO v_deal_id
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'depositos_mmg' AND column_name = 'deal_id';

  IF v_deal_id <> 1 THEN
    RAISE WARNING 'FAIL: depositos_mmg.deal_id was dropped — it is still load-bearing';
    v_fail := v_fail + 1;
  ELSE
    RAISE NOTICE 'PASS: depositos_mmg.deal_id kept (only the constraint was retired)';
  END IF;

  -- The shared-function guard.
  SELECT count(*) INTO v_shared
  FROM pg_trigger t
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE p.proname = 'update_updated_at_column' AND NOT t.tgisinternal;

  IF v_shared < 12 THEN
    RAISE WARNING 'FAIL: update_updated_at_column is attached to only % tables, expected 12', v_shared;
    v_fail := v_fail + 1;
  ELSE
    RAISE NOTICE 'PASS: shared update_updated_at_column still attached to 12 tables';
  END IF;

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'retire-deals-triggers: % check(s) FAILED', v_fail;
  END IF;

  RAISE NOTICE 'retire-deals-triggers: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT retire_deals_triggers;
