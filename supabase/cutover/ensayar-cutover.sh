#!/usr/bin/env bash
# Full local rehearsal of the 2026-09-27 cutover, on a throwaway Docker
# Postgres restored from a production dump. NEVER touches staging or
# production. Reproduces the steps used to validate R1/R2/R3 of
# odd/tasks/cutover-rates-and-legacy-parity.md.
#
#   bash supabase/cutover/ensayar-cutover.sh /path/to/produccion-*.dump
#
# Leaves a running container named `wacrm-ensayo` (Postgres on
# 127.0.0.1:55432, password `ensayo`) so the result can be inspected
# afterwards:
#   docker exec -it wacrm-ensayo psql -U supabase_admin -d postgres
#   psql "postgresql://supabase_admin:ensayo@127.0.0.1:55432/postgres"
#
# Remove it when done: docker rm -f wacrm-ensayo
set -euo pipefail

DUMP="${1:?usage: $0 /path/to/produccion-<timestamp>.dump}"
[[ -r "$DUMP" ]] || { echo "cannot read $DUMP" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CUTOVER_DIR="$REPO_ROOT/supabase/cutover"
IMAGE="public.ecr.aws/supabase/postgres:17.6.1.167" # matches production: Postgres 17

echo "== (1/6) starting a fresh Supabase Postgres 17 container (wacrm-ensayo)"
docker rm -f wacrm-ensayo >/dev/null 2>&1 || true
docker run -d --name wacrm-ensayo \
  -e POSTGRES_PASSWORD=ensayo -e POSTGRES_DB=postgres \
  -p 127.0.0.1:55432:5432 "$IMAGE" >/dev/null
for _ in $(seq 1 90); do
  docker exec wacrm-ensayo pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
sleep 3 # the entrypoint restarts postgres once after its own init scripts

psql_() { docker exec -i wacrm-ensayo psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }

echo "== (2/6) restoring $DUMP"
# The image's built-in auth/storage schemas are a different GoTrue/Storage
# schema revision than whatever shipped in production at dump time — restoring
# straight on top produces cascading "column does not exist" errors. Dropping
# them first (their extensions live in the separate `extensions` schema and
# are untouched) lets the dump recreate its own exact versions.
psql_ -c "DROP SCHEMA IF EXISTS auth CASCADE; DROP SCHEMA IF EXISTS storage CASCADE; DROP SCHEMA IF EXISTS public CASCADE;" >/dev/null
docker cp "$DUMP" wacrm-ensayo:/tmp/prod.dump
docker exec wacrm-ensayo pg_restore --no-owner --no-privileges -U supabase_admin -d postgres /tmp/prod.dump \
  > /tmp/ensayo-restore.log 2>&1 || true
# One real gap: ai_knowledge_chunks needs pgvector, not installed by default.
psql_ -c "CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;" >/dev/null
docker exec wacrm-ensayo pg_restore --no-owner --no-privileges -U supabase_admin -d postgres /tmp/prod.dump \
  >> /tmp/ensayo-restore.log 2>&1 || true
psql_ -c "CREATE EXTENSION IF NOT EXISTS pg_net;" >/dev/null
echo "   restore log: /tmp/ensayo-restore.log (only expected errors: schema/type/relation \"already exists\" on a second pass, and the ai_knowledge_chunks gap before pgvector was installed)"

echo "== (3/6) applying migrations 095-103"
docker cp "$MIGRATIONS_DIR" wacrm-ensayo:/tmp/migrations
for f in 095_remittance_calculator_document.sql 096_admin_locks_audit_sync.sql \
         097_operaciones_de_conversacion_rpc.sql 098_operator_corrections_rpcs.sql \
         099_deposit_review_rpcs.sql 100_destination_amount_calc.sql \
         101_operation_delivery_rpc.sql 102_operations_history_and_delivery_readiness.sql \
         103_calculator_rate_versions.sql; do
  docker exec wacrm-ensayo psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f "/tmp/migrations/$f" >/dev/null
done

echo "== (4/6) R1 — calculator rates seed (before 113)"
docker cp "$CUTOVER_DIR/2026-09-27-04-tasas-calculadora.sql" wacrm-ensayo:/tmp/r1.sql
docker exec wacrm-ensayo psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f /tmp/r1.sql

echo "== (5/6) applying migrations 104-118 (skip 112), 121, 123 — 119/120/122 already in production"
for f in 104_calculator_ledger_feed.sql 105_calculator_resolve_pending.sql \
         106_calculator_session_client_access.sql 107_destination_amount_rounds_up.sql \
         108_delivery_evidence_before_status.sql 109_capture_live_cerebro_functions.sql \
         110_n8n_fn_repoint.sql 111_usd_amount_rounds_down.sql \
         113_tasas_derives_from_the_calculator.sql 114_cutover_retire_sync_pipeline.sql \
         115_register_ai_handoff_columns.sql 116_dashboard_service_volume_rpc.sql \
         117_dashboard_operations_in_progress_rpc.sql 118_dashboard_operations_funnel_rpc.sql \
         121_financial_close_rpc.sql 123_add_beneficiary_rpc.sql; do
  docker exec wacrm-ensayo psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f "/tmp/migrations/$f" >/dev/null
done
echo "   post-113 check:"; psql_ -c "SELECT * FROM tasas;"

echo "== (6/6) R2 — legacy parity backfill, run twice to prove idempotence"
docker cp "$CUTOVER_DIR/2026-09-27-06-relleno-remesas-legado.sql" wacrm-ensayo:/tmp/r2.sql
docker exec wacrm-ensayo psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f /tmp/r2.sql > /tmp/ensayo-r2-run1.log
docker exec wacrm-ensayo psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f /tmp/r2.sql > /tmp/ensayo-r2-run2.log
echo "   run1 log: /tmp/ensayo-r2-run1.log ; run2 log: /tmp/ensayo-r2-run2.log (run2 must INSERT 0 rows into the backfill log table)"

echo
echo "== Done. wacrm-ensayo is left running for inspection:"
echo "     docker exec -it wacrm-ensayo psql -U supabase_admin -d postgres"
echo "   Remove it with: docker rm -f wacrm-ensayo"
