#!/usr/bin/env bash
# Vuelve PRODUCCION a la release anterior.
#
#   ./infra/deployment/rollback-wacrm-produccion.sh          # a `anterior`
#   ./infra/deployment/rollback-wacrm-produccion.sh <sha>    # a una concreta
#
# NO compila, NO sube nada y NO borra la release de la que se viene: si el
# rollback tampoco sirve, se puede volver a la de antes. Solo mueve un symlink
# y reinicia el pm2 que toca — ninguno mas.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$AQUI/lib-comun.sh"
source "$AQUI/lib-produccion.sh"

SSH_P=(${SSH_OPTS:-} "$HOST_PRODUCCION")
remoto() { ssh "${SSH_P[@]}" "$@"; }

DESTINO_SHA="${1:-}"

paso "Estado actual"
ACTUAL="$(remoto "readlink -f $RELEASES_PRODUCCION/current 2>/dev/null || true")"
[[ -n "$ACTUAL" ]] || fatal "no hay release activa en $RELEASES_PRODUCCION"
verde "  sirviendo ahora  $ACTUAL"

if [[ -n "$DESTINO_SHA" ]]; then
    VOLVER="$RELEASES_PRODUCCION/$DESTINO_SHA"
else
    VOLVER="$(remoto "readlink -f $RELEASES_PRODUCCION/anterior 2>/dev/null || true")"
    [[ -n "$VOLVER" ]] || fatal \
        "no hay marca \`anterior\`. Dime a cual volver:  $0 <sha>
  Las releases que hay estan en $RELEASES_PRODUCCION."
fi

[[ "$VOLVER" != "$ACTUAL" ]] || fatal "esa ya es la release activa; no hay nada que hacer"
remoto "test -f $VOLVER/.next/BUILD_ID" \
    || fatal "$VOLVER no tiene un build utilizable; no se toca nada"
ID_VOLVER="$(remoto "cat $VOLVER/.next/BUILD_ID")"
verde "  volviendo a      $VOLVER  (BUILD_ID $ID_VOLVER)"

paso "Cambiando"
# `anterior` pasa a ser la que estamos dejando: asi este mismo script deshace
# el rollback si tampoco resolvia.
remoto "ln -sfn $ACTUAL $RELEASES_PRODUCCION/anterior && \
        ln -sfn $VOLVER $RELEASES_PRODUCCION/current"
remoto "pm2 restart $PM2_APP_PRODUCCION --update-env >/dev/null 2>&1"
verde "  current  -> $VOLVER"
verde "  anterior -> $ACTUAL   (sigue entera, se puede volver)"

paso "Comprobando lo que se sirve"
ok=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if build_id_vivo_en_produccion "$ID_VOLVER"; then ok=1; break; fi
    sleep 3
done
[[ -n "$ok" ]] || fatal "$DOMINIO_PRODUCCION no sirve $ID_VOLVER.
  El symlink ya apunta a $VOLVER; mira pm2 logs $PM2_APP_PRODUCCION."
verde "  $DOMINIO_PRODUCCION sirve $ID_VOLVER"
