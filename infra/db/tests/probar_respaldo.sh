#!/usr/bin/env bash
# Guard test for infra/db/respaldo-diario.sh retention.
# No network, no docker, no real dumps: builds fixtures in a temp dir and runs
# the wrapper with SIN_RESPALDAR=1 so only the pruning logic executes.
#
#   bash infra/db/tests/probar_respaldo.sh
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$AQUI/../respaldo-diario.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILS=0

ok()   { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

[[ -f "$SCRIPT" ]] || { echo "FAIL script not found: $SCRIPT" >&2; exit 1; }

mk() {  # mk <name> <days-ago>
  local f="$TMP/$1"
  : > "$f"; : > "$f.list"; : > "$f.sha256"
  touch -d "$2 days ago" "$f" "$f.list" "$f.sha256"
}

mk produccion-recent.dump 1
mk produccion-old-kept.dump 40
mk produccion-old-pruned.dump 50
mk staging-old.dump 50
: > "$TMP/nota.txt"

RESPALDO_DIR="$TMP" SIN_RESPALDAR=1 KEEP_DIAS=30 KEEP_MIN=2 \
  bash "$SCRIPT" produccion >/dev/null 2>&1
RC=$?

[[ $RC -eq 0 ]] && ok "exits 0" || fail "exit code $RC"

[[ -f "$TMP/produccion-recent.dump" ]] && ok "recent dump kept" || fail "recent dump deleted"
[[ -f "$TMP/produccion-old-kept.dump" ]] && ok "old dump inside KEEP_MIN kept" || fail "KEEP_MIN dump deleted"
[[ ! -e "$TMP/produccion-old-pruned.dump" ]] && ok "old dump beyond retention deleted" || fail "pruned dump still present"
[[ ! -e "$TMP/produccion-old-pruned.dump.list" ]] && ok "pruned .list deleted" || fail "pruned .list still present"
[[ ! -e "$TMP/produccion-old-pruned.dump.sha256" ]] && ok "pruned .sha256 deleted" || fail "pruned .sha256 still present"
[[ -f "$TMP/staging-old.dump" ]] && ok "other environment untouched" || fail "staging dump was touched"
[[ -f "$TMP/nota.txt" ]] && ok "unrelated file untouched" || fail "unrelated file was touched"

# Rejects an unknown environment without touching the directory.
OUT=$(RESPALDO_DIR="$TMP" SIN_RESPALDAR=1 bash "$SCRIPT" otra 2>&1); RC=$?
[[ $RC -ne 0 ]] && ok "unknown environment rejected" || fail "unknown environment accepted"

if [[ $FAILS -gt 0 ]]; then
  echo "RESULT: $FAILS case(s) FAILED" >&2
  exit 1
fi
echo "RESULT: ALL PASS"
