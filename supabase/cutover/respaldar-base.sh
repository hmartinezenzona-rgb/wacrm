#!/usr/bin/env bash
# Full backup of a WaCRM Supabase database before the cutover (Free plan: no
# automatic backups, Supabase recommends exporting the data yourself).
#
#   bash supabase/cutover/respaldar-base.sh produccion   # reads ~/.config/wacrm/prod-db.env    (PROD_DATABASE_URL)
#   bash supabase/cutover/respaldar-base.sh staging      # reads ~/.config/wacrm/staging-db.env (STAGING_DATABASE_URL)
#
# pg_dump 17 runs inside the official postgres:17 image (production is Postgres
# 17). Output: ~/wacrm-respaldos/<entorno>-<UTC timestamp>.dump (custom format,
# restorable with pg_restore) + a .list with its table of contents and a .sha256.
# The connection string never appears on screen or in the process list.
set -euo pipefail

ENTORNO="${1:-}"
case "$ENTORNO" in
  produccion) ENVF=~/.config/wacrm/prod-db.env;    VAR=PROD_DATABASE_URL;    REF=hqztotshnlzaiziwjyzh ;;
  staging)    ENVF=~/.config/wacrm/staging-db.env; VAR=STAGING_DATABASE_URL; REF=kolppplawzdsjfydwejr ;;
  *) echo "uso: $0 produccion|staging" >&2; exit 2 ;;
esac
[[ -r "$ENVF" ]] || { echo "falta $ENVF con $VAR=postgresql://..." >&2; exit 1; }
URL="$(grep -E "^$VAR=" "$ENVF" | head -1 | cut -d= -f2- | tr -d "\"'")"
[[ -n "$URL" ]] || { echo "$ENVF no trae $VAR" >&2; exit 1; }
# Guard: the URL must be the expected project, never the other one.
[[ "$URL" == *"$REF"* ]] || { echo "la URL de $ENVF no es del proyecto $REF ($ENTORNO). No se hace nada." >&2; exit 1; }

DEST=~/wacrm-respaldos; mkdir -p "$DEST"; chmod 700 "$DEST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ENTORNO-$STAMP.dump"

echo "== Respaldo de $ENTORNO ($REF) -> $DEST/$OUT"
# The URL goes in through the environment (-e VAR), not on the command line.
docker run --rm --user "$(id -u):$(id -g)" -e PGURL="$URL" -v "$DEST":/out postgres:17 \
  sh -c 'pg_dump --format=custom --no-owner --no-privileges \
           --schema=public --schema=auth --schema=storage \
           --file=/out/'"$OUT"' "$PGURL"'

docker run --rm --user "$(id -u):$(id -g)" -v "$DEST":/out postgres:17 pg_restore --list "/out/$OUT" > "$DEST/$OUT.list"
( cd "$DEST" && sha256sum "$OUT" > "$OUT.sha256" )
chmod 600 "$DEST/$OUT" "$DEST/$OUT.list" "$DEST/$OUT.sha256"

echo "== Listo"
ls -lh "$DEST/$OUT"
echo "  tablas con datos: $(grep -c ' TABLE DATA ' "$DEST/$OUT.list")"
echo "  funciones:        $(grep -c ' FUNCTION ' "$DEST/$OUT.list")"
echo "  sha256:           $(cut -c1-16 "$DEST/$OUT.sha256")..."
