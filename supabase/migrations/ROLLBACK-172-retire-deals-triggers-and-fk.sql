-- =====================================================================
-- ROLLBACK for 172_retire_deals_triggers_and_fk.sql
--
-- Restores the seven inert triggers on `deals` and the
-- `depositos_mmg_deal_id_fkey` foreign key to exactly the definitions
-- read from the staging catalog before the migration was applied.
--
-- Behavioural note: restoring these is only meaningful while `deals`
-- still exists. Once 6.4 drops the table this rollback cannot run, by
-- construction.
--
-- Idempotent: each trigger is created only if absent.
-- =====================================================================

DO $$
DECLARE
  v_trigger text;
  v_defs text[][] := ARRAY[
    ARRAY['deals_insert_notify',
          'CREATE TRIGGER deals_insert_notify AFTER INSERT ON public.deals FOR EACH ROW EXECUTE FUNCTION notify_deal_insert()'],
    ARRAY['deals_sync_tags',
          'CREATE TRIGGER deals_sync_tags AFTER INSERT OR DELETE OR UPDATE OF stage_id, contact_id ON public.deals FOR EACH ROW EXECUTE FUNCTION trg_sync_tags_deal()'],
    ARRAY['trg_admin_guard_deals_stage',
          'CREATE TRIGGER trg_admin_guard_deals_stage BEFORE INSERT OR UPDATE OF stage_id ON public.deals FOR EACH ROW EXECUTE FUNCTION deals_admin_completion_guard()'],
    ARRAY['trg_cancel_operacion_on_deal_delete',
          'CREATE TRIGGER trg_cancel_operacion_on_deal_delete AFTER DELETE ON public.deals FOR EACH ROW EXECUTE FUNCTION cerebro_cancel_operacion_on_deal_delete()'],
    ARRAY['trg_cerrar_deal_entregado',
          'CREATE TRIGGER trg_cerrar_deal_entregado BEFORE INSERT OR UPDATE OF stage_id ON public.deals FOR EACH ROW EXECUTE FUNCTION cerebro_cerrar_deal_entregado()'],
    ARRAY['trg_liberar_depositos_al_borrar_deal',
          'CREATE TRIGGER trg_liberar_depositos_al_borrar_deal BEFORE DELETE ON public.deals FOR EACH ROW EXECUTE FUNCTION liberar_depositos_al_borrar_deal()'],
    ARRAY['trg_sync_operacion_al_crear_deal',
          'CREATE TRIGGER trg_sync_operacion_al_crear_deal AFTER INSERT ON public.deals FOR EACH ROW EXECUTE FUNCTION cerebro_crear_operacion_al_crear_deal()']
  ];
  i integer;
BEGIN
  FOR i IN 1 .. array_length(v_defs, 1) LOOP
    v_trigger := v_defs[i][1];
    IF NOT EXISTS (
      SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = 'deals'
        AND t.tgname = v_trigger
        AND NOT t.tgisinternal
    ) THEN
      EXECUTE v_defs[i][2];
    END IF;
  END LOOP;
END $$;

ALTER TABLE public.depositos_mmg
  DROP CONSTRAINT IF EXISTS depositos_mmg_deal_id_fkey;

ALTER TABLE public.depositos_mmg
  ADD CONSTRAINT depositos_mmg_deal_id_fkey
  FOREIGN KEY (deal_id) REFERENCES public.deals(id) ON DELETE SET NULL;
