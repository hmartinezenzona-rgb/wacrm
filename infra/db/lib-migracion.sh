#!/usr/bin/env bash
# Piezas comunes de staging-migracion.sh, produccion-migracion.sh y correccion-produccion.sh (se hace `source`).

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

# Ruta absoluta de un fichero que tiene que existir.
fichero() { [[ -f "$1" ]] || die "no existe el fichero: $1"; realpath "$1"; }

# Quita lo que cada paso pone por su cuenta: la transaccion y el \set de las aserciones.
quitar_tx() { grep -v -E '^(\\set ON_ERROR_STOP on|BEGIN;|ROLLBACK;|COMMIT;)$' "$1"; }

# Lee SQL por stdin y lo corre contra staging (postgres:17 en Docker, URL de .env.staging).
psql_staging() {
    [[ -f "$RAIZ/.env.staging" ]] || die "falta $RAIZ/.env.staging (CRM_STAGING_DATABASE_URL)"
    ( cd "$RAIZ" && docker run --rm -i --env-file .env.staging postgres:17 \
        sh -c 'psql -X -q -A -t "$CRM_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f -' )
}

# Primera linea ERROR de una salida de psql (vacio si no hay), sin uuids.
primer_error() { grep -m1 -oE 'ERROR: .{0,90}' "$1" | sed -E 's/[0-9a-f]{8}-[0-9a-f-]{4,}/<uuid>/g'; }

# ─── token y API de Supabase (Management API) ───────────────────────────────
# Variables que pone el script que hace `source` de esta lib:
#   TOKEN_FILE  ruta del fichero con SUPABASE_ACCESS_TOKEN=... (modo 600)
#   TRABAJO     directorio temporal propio del script (lo limpia el trap)
#   API         URL base del proyecto, p. ej. https://api.supabase.com/v1/projects/<ref>
#   LOG         fichero donde se anota cada respuesta de la API
# cargar_token deja el token en TOKEN; api_post deja el codigo en API_CODE y la respuesta en API_RESP.
cargar_token() {
    command -v jq >/dev/null || die "hace falta jq"
    command -v curl >/dev/null || die "hace falta curl"
    [[ -f "$TOKEN_FILE" ]] || die "falta el fichero del token: $TOKEN_FILE (con SUPABASE_ACCESS_TOKEN=...)"
    local modo; modo=$(stat -c %a "$TOKEN_FILE")
    [[ "$modo" == 600 ]] || die "$TOKEN_FILE tiene permisos $modo y tienen que ser 600 (chmod 600)"
    TOKEN=$(grep -m1 '^SUPABASE_ACCESS_TOKEN=' "$TOKEN_FILE" | cut -d= -f2- | tr -d '"'"'"'\r')
    [[ -n "$TOKEN" ]] || die "$TOKEN_FILE no tiene SUPABASE_ACCESS_TOKEN="
}

# POST <ruta> <fichero-json>: deja el codigo en API_CODE y la respuesta en API_RESP.
api_post() {
    API_RESP="$TRABAJO/resp.$RANDOM"
    API_CODE=$(curl -sS -o "$API_RESP" -w '%{http_code}' \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") \
        -X POST -H 'Content-Type: application/json' --data-binary "@$2" "$API$1") || API_CODE=000
    { echo "### POST $1 -> $API_CODE"; head -c 2000 "$API_RESP" 2>/dev/null; echo; } >> "$LOG"
}
api_ok() { [[ "$API_CODE" == 2* ]]; }
api_mensaje() { jq -r '.message // .error // .' "$API_RESP" 2>/dev/null | head -3; }
