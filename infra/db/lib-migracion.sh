#!/usr/bin/env bash
# Piezas comunes de staging-migracion.sh y produccion-migracion.sh (se hace `source`).

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
