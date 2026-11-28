#!/usr/bin/env bash
# Guard: repo migration numbering.
#
#   - No two migration files may share a numeric prefix. The two collisions
#     that already exist are documented and allowlisted:
#       088  088_historial_paginado + 088b_historial_permisos_exactos
#       168  168_late_mmg_email_recross + 168_tags_off_delivered_operations
#     Both are already recorded in production's ledger, so renaming them now
#     would desync history.
#   - Every migration >= 127 ships exactly one ROLLBACK-<num>-*.sql.
#     The 79 legacy migrations <= 126 predate the rollback convention.
#
#   bash infra/db/tests/probar_numeracion.sh
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${MIGRATIONS_DIR:-$AQUI/../../../supabase/migrations}"
ALLOWED_DUP=" 088 168 "
FAILS=0

ok()   { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

[[ -d "$DIR" ]] || { echo "FAIL migrations dir not found: $DIR" >&2; exit 1; }

# Numeric prefix -> files.
declare -A CNT=()
for f in "$DIR"/*.sql; do
  b="$(basename "$f")"
  [[ "$b" == ROLLBACK-* ]] && continue
  [[ "$b" =~ ^([0-9]+)([a-z]?)_ ]] || continue
  n="${BASH_REMATCH[1]}"
  CNT["$n"]+="$b "
done

DUP=0
for n in "${!CNT[@]}"; do
  # A letter suffix (088b) belongs to the same number on purpose.
  read -r -a files <<< "${CNT[$n]}"
  if [[ ${#files[@]} -gt 1 && "$ALLOWED_DUP" != *" $n "* ]]; then
    fail "number $n used by: ${CNT[$n]}"
    DUP=$((DUP + 1))
  fi
done
[[ $DUP -eq 0 ]] && ok "no undocumented duplicate numbers"

MISSING=0
for f in "$DIR"/*.sql; do
  b="$(basename "$f")"
  [[ "$b" == ROLLBACK-* ]] && continue
  [[ "$b" =~ ^([0-9]+[a-z]?)_(.+)\.sql$ ]] || continue
  prefix="${BASH_REMATCH[1]}"
  slug="${BASH_REMATCH[2]}"
  # Compare as base 10: 049 is not valid octal.
  if [[ $((10#${prefix%%[a-z]*})) -lt 127 ]]; then
    continue
  fi
  shopt -s nullglob
  rb=("$DIR"/ROLLBACK-"$prefix"-"$slug".sql)
  shopt -u nullglob
  if [[ ${#rb[@]} -ne 1 ]]; then
    fail "$b has ${#rb[@]} ROLLBACK-${prefix}-${slug}.sql (want 1)"
    MISSING=$((MISSING + 1))
  fi
done
if [[ $MISSING -eq 0 ]]; then
  ok "every migration >= 127 has its own ROLLBACK"
fi

if [[ $FAILS -gt 0 ]]; then
  echo "RESULT: $FAILS case(s) FAILED" >&2
  exit 1
fi
echo "RESULT: ALL PASS"
