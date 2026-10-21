#!/usr/bin/env bash
# Levanta el panel de ESTE checkout en local contra la base de STAGING.
#
#   ./infra/deployment/panel-local-staging.sh [puerto]     (por defecto 3100)
#
# Sirve para ver un cambio funcionando antes de publicarlo. El dueno inicia
# sesion el mismo en el navegador: aqui no se teclea ni se pide ninguna
# contrasena. `/api/promotions/etecsa` da 500 en local (no hay service key):
# es lo esperado.
#
# Solo valores publicos (NEXT_PUBLIC_*) viven en el fichero de env. El script
# NUNCA los imprime; solo dice si el fichero falta.
set -euo pipefail

PUERTO="${1:-3100}"
ENV_STAGING="$HOME/.config/wacrm/staging-build.env"

[[ "$PUERTO" =~ ^[0-9]+$ ]] || { echo "ERROR: el puerto debe ser un numero, no '$PUERTO'" >&2; exit 1; }
[[ -f "$ENV_STAGING" ]] || {
    echo "ERROR: falta $ENV_STAGING (valores publicos de build de staging)." >&2
    exit 1
}

set -a
# shellcheck disable=SC1090
. "$ENV_STAGING"
set +a
export NEXT_PUBLIC_SITE_URL="http://localhost:$PUERTO"

echo "Panel local contra staging en $NEXT_PUBLIC_SITE_URL (Ctrl+C para parar)"
exec npx --no-install next dev -p "$PUERTO"
