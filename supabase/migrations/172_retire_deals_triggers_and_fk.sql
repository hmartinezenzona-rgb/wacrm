-- =====================================================================
-- 172 — retire the `deals` foreign key and the inert triggers (WU9)
--
-- Numbered 172, not 171: the concurrent session on this branch already
-- committed a second `171_requested_amount_target.sql`, and its own
-- handoff (odd/tasks/HANDOFF-production-registrar-168-170-171.md) asks
-- that the migrations NOT in production be the ones renumbered. This one
-- is not in production.
--
-- PROBLEM (item 6.4): `DROP TABLE deals, pipelines, pipeline_stages` is
-- the end state of this feature, and it cannot run today. Measured
-- against the live staging catalog, not inferred:
--
--   1. `depositos_mmg_deal_id_fkey` — a live 259-row table still holds a
--      foreign key to `deals`. This is the hard DDL blocker.
--   2. Nine triggers sit on `deals`. They are NOT blockers — a trigger
--      dies with its table — but they are a live hazard while the table
--      still exists.
--
-- WHY ONLY SEVEN OF THE NINE ARE DROPPED HERE. Nothing INSERTs into
-- `deals` and nothing DELETEs from it any more; only three functions
-- update it (`cerebro_aplicar_nombre_confirmado`, reached indirectly
-- through `trg_zz_nombre_confirmado_zelle` on `messages`, plus
-- `crm_forzar_verificacion` and `crm_verificar_deposito`), and all three
-- write **only `notes` and `updated_at`** — never `stage_id`, never
-- `contact_id`. So every trigger keyed on INSERT, on DELETE, or on
-- `UPDATE OF stage_id`/`contact_id` can no longer fire. That is the
-- seven dropped below.
--
-- The two deliberately kept:
--
--   * `set_updated_at` (BEFORE UPDATE) is still live but harmless — the
--     writers set `updated_at` explicitly anyway. Its function,
--     `update_updated_at_column`, is shared by eleven other tables
--     (`accounts`, `automations`, `broadcasts`, `contacts`,
--     `conversations`, `flows`, `message_templates`, `objects`,
--     `profiles`, `quick_replies`, `whatsapp_config`) and must NEVER be
--     dropped with this table.
--
--   * `trg_sync_z_benef_desde_deal` (AFTER INSERT OR UPDATE OF notes) is
--     **live and behavioral** and must NOT be touched yet. Its function
--     `cerebro_sync_benef_trigger` reads `NEW.notes` for
--     `ENTREGA EN USD: Clasica|Tropical|Efectivo` and writes
--     `remittance_operations.delivery_method` — an indirect write into
--     the operation, which is exactly the class of trap this feature has
--     been caught by seven times. It stays until WU6d repoints that
--     writer at the 162 structured path. **This is the one real blocker
--     this migration leaves behind, and it is WU6d's, by design.**
--
-- SCOPE GUARD: this migration does NOT drop the table, does NOT drop the
-- `deal_id` column, does NOT drop the eight now-orphaned trigger
-- functions (no caller check has been run — an orphan is harmless, a
-- wrongly dropped function is not), and does NOT touch RLS.
--
-- STILL NOT ENOUGH FOR 6.4. Eleven public functions still reference
-- `deals` and would break at runtime after the drop even though the DDL
-- itself would succeed: `cerebro_aplicar_nombre_confirmado`,
-- `cerebro_cruzar_depositos`, `cerebro_marcar_destino_usd`,
-- `cerebro_registrar_deposito`, `cerebro_registrar_reparto_multiple`,
-- `cerebro_sync_beneficiarios`, `crm_comprobantes_de_operacion`,
-- `crm_forzar_verificacion`, `crm_verificar_deposito`,
-- `notify_deal_stage_change`, `redeem_invitation`. The concurrent
-- session's handoff adds `cerebro_cruzar_pendientes` and
-- `cerebro_recruzar_depositos_tardios`, which still read `deals.notes`.
--
-- Idempotent and existence-guarded: safe to re-run.
--
-- ROLLBACK: ROLLBACK-172-retire-deals-triggers-and-fk.sql
-- =====================================================================

DO $$
DECLARE
  v_trigger text;
  v_triggers text[] := ARRAY[
    'deals_insert_notify',
    'deals_sync_tags',
    'trg_admin_guard_deals_stage',
    'trg_cancel_operacion_on_deal_delete',
    'trg_cerrar_deal_entregado',
    'trg_liberar_depositos_al_borrar_deal',
    'trg_sync_operacion_al_crear_deal'
  ];
  v_dropped integer := 0;
BEGIN
  FOREACH v_trigger IN ARRAY v_triggers LOOP
    IF EXISTS (
      SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = 'deals'
        AND t.tgname = v_trigger
        AND NOT t.tgisinternal
    ) THEN
      EXECUTE format('DROP TRIGGER %I ON public.deals', v_trigger);
      v_dropped := v_dropped + 1;
    END IF;
  END LOOP;

  RAISE NOTICE '172: dropped % of 7 inert triggers on deals', v_dropped;
END $$;

-- The constraint only. `depositos_mmg.deal_id` stays: `cerebro_objetivo_envio`
-- and `cerebro_saldo_envio` are still keyed by it, and 255 of 259 rows hold NULL.
ALTER TABLE public.depositos_mmg
  DROP CONSTRAINT IF EXISTS depositos_mmg_deal_id_fkey;

-- =====================================================================
-- VALIDATE ON STAGING — read the catalog back:
--   SELECT tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
--   WHERE c.relname = 'deals' AND NOT t.tgisinternal;
--   -- expect exactly: set_updated_at, trg_sync_z_benef_desde_deal
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-172-retire-deals-triggers-and-fk.sql
-- =====================================================================
