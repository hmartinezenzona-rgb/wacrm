# Legacy assertions (not run by the staging cycle)

The staging runner globs `supabase/staging/assertions/*.sql` (non-recursive), so
files in this folder are kept for reference and are never executed.

- `deal-insert-creates-operation.sql` (migration 125): tests that inserting a
  deal creates its `remittance_operations` row. Migration 172 deliberately
  dropped `trg_sync_operacion_al_crear_deal` and the other deal triggers
  because nothing inserts into `deals` any more. The behavior it asserts is
  retired, not broken.
- `tag-sync-without-deals.sql` (migration 168): its fixtures create deals and
  rely on the retired deal→operation triggers to produce completed operations.
  It also asserts that `deals_sync_tags` still exists, which 172 removed. The
  live `sync_tags_cliente` is covered by `../sync-tags-cliente.sql` instead.

Do not copy these back into the runner without rewriting their fixtures to
insert `remittance_operations` directly. See `odd/tasks/eliminate-deals.md`.
