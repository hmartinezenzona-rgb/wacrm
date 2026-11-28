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
SELLO="$(date +%Y%m%d%H%M%S)"
LOG="${TMPDIR:-/tmp}/correccion-produccion-$SELLO.log"

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

# ─── token y API (lib-migracion.sh) ────────────────────────────────────────
cargar_token
TRABAJO=$(mktemp -d); trap 'rm -rf "$TRABAJO"' EXIT
jq -Rs '{query: .}' "$RUTA" > "$TRABAJO/q.json" || die "no pude leer $RUTA"

api_post /database/query "$TRABAJO/q.json"
if ! api_ok; then
    echo "ERROR (HTTP $API_CODE): $(api_mensaje)"
    exit 1
fi
jq -c . "$API_RESP" 2>/dev/null || cat "$API_RESP"
