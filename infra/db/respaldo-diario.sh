#!/usr/bin/env bash
# Daily WaCRM backup: runs supabase/cutover/respaldar-base.sh, verifies the new
# dump, then prunes old dumps with a floor of KEEP_MIN newest files.
#
#   infra/db/respaldo-diario.sh [produccion|staging]     default: produccion
#
# Environment:
#   RESPALDO_DIR   dump directory        (default ~/wacrm-respaldos)
#   KEEP_DIAS      retention in days     (default 30)
#   KEEP_MIN       newest files kept     (default 14)
#   SIN_RESPALDAR  =1 skips the dump, only prunes (guard tests)
#   DRY_RUN        =1 prints deletions without removing anything
#
# Guard test: bash infra/db/tests/probar_respaldo.sh
set -euo pipefail

ENTORNO="${1:-produccion}"
case "$ENTORNO" in
  produccion|staging) ;;
  *) echo "uso: $0 produccion|staging" >&2; exit 2 ;;
esac

DIR="${RESPALDO_DIR:-$HOME/wacrm-respaldos}"
KEEP_DIAS="${KEEP_DIAS:-30}"
KEEP_MIN="${KEEP_MIN:-14}"
SIN_RESPALDAR="${SIN_RESPALDAR:-0}"
DRY_RUN="${DRY_RUN:-0}"

for v in KEEP_DIAS KEEP_MIN; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "$v must be numeric (got '${!v}')" >&2; exit 2; }
done

mkdir -p "$DIR"; chmod 700 "$DIR"

# ── 1. dump ────────────────────────────────────────────────────────────────
if [[ "$SIN_RESPALDAR" != "1" ]]; then
  AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "$AQUI/../../supabase/cutover/respaldar-base.sh" "$ENTORNO"

  NEWEST="$(find "$DIR" -maxdepth 1 -type f -name "$ENTORNO-*.dump" \
            -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
  [[ -n "$NEWEST" && -s "$NEWEST" ]] || { echo "backup failed: no new $ENTORNO dump" >&2; exit 1; }
  [[ -s "$NEWEST.list" ]] || { echo "backup failed: missing table of contents for $NEWEST" >&2; exit 1; }
  ( cd "$DIR" && sha256sum -c "$(basename "$NEWEST").sha256" >/dev/null ) \
    || { echo "backup failed: sha256 mismatch for $NEWEST" >&2; exit 1; }
  echo "verified $(basename "$NEWEST")"
fi

# ── 2. retention ───────────────────────────────────────────────────────────
NOW="$(date +%s)"
# Newest first.
mapfile -t DUMPS < <(find "$DIR" -maxdepth 1 -type f -name "$ENTORNO-*.dump" \
                      -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)

i=0
for f in "${DUMPS[@]}"; do
  i=$((i + 1))
  [[ $i -le $KEEP_MIN ]] && continue
  MTIME="$(stat -c %Y "$f")"
  AGE_DIAS=$(( (NOW - MTIME) / 86400 ))
  [[ $AGE_DIAS -le $KEEP_DIAS ]] && continue
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would delete $(basename "$f") (${AGE_DIAS}d)"
  else
    rm -f "$f" "$f.list" "$f.sha256"
    echo "deleted $(basename "$f") (${AGE_DIAS}d)"
  fi
done

RESTANTES=$(find "$DIR" -maxdepth 1 -type f -name "$ENTORNO-*.dump" | wc -l)
echo "retention done: $ENTORNO, $RESTANTES dump(s) present, keep<=${KEEP_DIAS}d or newest ${KEEP_MIN}"
