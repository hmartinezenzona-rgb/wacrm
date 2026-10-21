#!/usr/bin/env bash
# Corrige datos en PRODUCCION: ejecuta UN fichero SQL por la Management API de Supabase.
#
#   correccion-produccion.sh <correccion.sql> --confirmar
#
# Sin --confirmar no hace nada. Se niega con fichero vacio, con DROP TABLE, TRUNCATE,
# DROP SCHEMA o ALTER TABLE ... DROP COLUMN (los cambios de esquema van por migraciones).
# El token sale de ~/.config/wacrm/supabase-token.env (modo 600, SUPABASE_ACCESS_TOKEN=...).
# Nunca se imprime ni va en argv: curl lo lee de una configuracion que se genera en un descriptor.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-migracion.sh"

REF="hqztotshnlzaiziwjyzh"
API="https://api.supabase.com/v1/projects/$REF"
TOKEN_FILE="$HOME/.config/wacrm/supabase-token.env"

uso() { echo "uso: correccion-produccion.sh <correccion.sql> --confirmar" >&2; exit 2; }

FICHERO=""; CONFIRMAR=0
for a in "$@"; do
    case "$a" in
        --confirmar) CONFIRMAR=1 ;;
        *) [[ -z "$FICHERO" ]] || uso; FICHERO="$a" ;;
    esac
done
[[ -n "$FICHERO" ]] || uso
if [[ "$CONFIRMAR" -ne 1 ]]; then
    echo "Se niega: falta --confirmar. Esto cambia datos de PRODUCCION; con el go-ahead del dueno: correccion-produccion.sh $FICHERO --confirmar" >&2
    exit 2
fi

RUTA=$(fichero "$FICHERO")   # sale con error si no existe
grep -q '[^[:space:]]' "$RUTA" || die "el fichero esta vacio: $RUTA"

# Sentencias prohibidas: se buscan sin comentarios SQL y con los saltos de linea juntos.
PLANO=$(sed 's/--.*$//' "$RUTA" | tr '\n\r\t' '   ' | tr -s ' ')
if grep -qiE 'DROP[[:space:]]+(TABLE|SCHEMA)|TRUNCATE|ALTER[[:space:]]+TABLE[[:space:]].*DROP[[:space:]]+COLUMN' <<<"$PLANO"; then
    die "el fichero contiene DROP TABLE, TRUNCATE, DROP SCHEMA o ALTER TABLE ... DROP COLUMN; eso es esquema y va por una migracion"
fi

# ─── token y API (mismo criterio que produccion-migracion.sh) ───────────────
command -v jq >/dev/null || die "hace falta jq"
command -v curl >/dev/null || die "hace falta curl"
[[ -f "$TOKEN_FILE" ]] || die "falta el fichero del token: $TOKEN_FILE (con SUPABASE_ACCESS_TOKEN=...)"
MODO=$(stat -c %a "$TOKEN_FILE")
[[ "$MODO" == 600 ]] || die "$TOKEN_FILE tiene permisos $MODO y tienen que ser 600 (chmod 600)"
TOKEN=$(grep -m1 '^SUPABASE_ACCESS_TOKEN=' "$TOKEN_FILE" | cut -d= -f2- | tr -d '"'"'"'\r')
[[ -n "$TOKEN" ]] || die "$TOKEN_FILE no tiene SUPABASE_ACCESS_TOKEN="

TRABAJO=$(mktemp -d); trap 'rm -rf "$TRABAJO"' EXIT
jq -Rs '{query: .}' "$RUTA" > "$TRABAJO/q.json" || die "no pude leer $RUTA"

CODIGO=$(curl -sS -o "$TRABAJO/resp.json" -w '%{http_code}' \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") \
    -X POST -H 'Content-Type: application/json' --data-binary "@$TRABAJO/q.json" \
    "$API/database/query") || CODIGO=000

if [[ "$CODIGO" != 2* ]]; then
    echo "ERROR (HTTP $CODIGO): $(jq -r '.message // .error // .' "$TRABAJO/resp.json" 2>/dev/null | head -3)"
    exit 1
fi
jq -c . "$TRABAJO/resp.json" 2>/dev/null || cat "$TRABAJO/resp.json"
