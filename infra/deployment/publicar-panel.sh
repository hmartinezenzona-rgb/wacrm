#!/usr/bin/env bash
# Publica el panel de PRODUCCION en dos ordenes cortas.
#
#   ./infra/deployment/publicar-panel.sh compilar [--sin-pruebas]
#   ./infra/deployment/publicar-panel.sh publicar <sha>
#   ./infra/deployment/publicar-panel.sh servido
#
# `compilar` se ejecuta desde el worktree de build (el que tiene la rama
# release/prod-*): comprueba, compila en Docker con node 20 y deja un artifact
# en dist/. `publicar` solo envuelve `desplegar-wacrm-produccion.sh`. Ninguna
# de las dos decide QUE se publica ni CUANDO: eso es de quien dirige la
# publicacion, con el visto bueno explicito del dueno cada vez.
#
# POR QUE DOCKER. El host trae node 26 y `build-wacrm.sh` exige node 20; en un
# worktree, ademas, `.git` es un FICHERO que apunta al git dir comun, asi que
# hay que montarlo dentro del contenedor o git no funciona alli.
#
# Nada de esto imprime secretos: el env de build se pasa por RUTA, nunca por
# valor, y el log del build se queda en dist/ en vez de volcarse.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-comun.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-produccion.sh"

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(raiz_repo "$AQUI")" || fatal "esto no esta dentro de un repositorio git"
DIST="$RAIZ/dist"
ENV_BUILD="$RAIZ/infra/deployment/wacrm.produccion.build.env"

# Quita los codigos ANSI y las lineas `**` (los avisos post-cuanticos de ssh).
limpiar() { sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep --line-buffered -v '^\*\*' || true; }

# El manifiesto debe ser de produccion Y apuntar a la base de produccion; el
# nombre del entorno lo escribe quien compila, el project ref dice contra que
# base habla el bundle de verdad.
manifiesto_de_produccion() {
    local m="$1" entorno ref
    [[ -f "$m" ]] || fatal "no encuentro el manifiesto $m"
    entorno="$(sed -nE 's/.*"environment"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$m")"
    ref="$(sed -nE 's/.*"supabase_project_ref"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$m")"
    [[ "$entorno" == "$ENTORNO_PRODUCCION" ]] \
        || fatal "el manifiesto es del entorno '${entorno:-?}', no de $ENTORNO_PRODUCCION"
    [[ "$ref" == "$PROJECT_REF_PRODUCCION" ]] \
        || fatal "el manifiesto apunta al proyecto '${ref:-?}', no a $PROJECT_REF_PRODUCCION"
}

compilar() {
    local sin_pruebas=0
    [[ "${1:-}" == "--sin-pruebas" ]] && sin_pruebas=1

    # Los ficheros sin seguimiento no cuentan: el artifact corresponde a un
    # commit, y lo que no esta en el commit no entra en el build.
    [[ -z "$(git -C "$RAIZ" status --porcelain --untracked-files=no)" ]] \
        || fatal "hay cambios sin confirmar; un artifact debe corresponder a un commit"
    [[ -f "$ENV_BUILD" ]] || fatal "falta $ENV_BUILD (esta fuera de git).
  Copialo con permisos 0600 desde otro worktree, p. ej.:
    cp ~/wacrm-worktrees/mejora-legacy/infra/deployment/wacrm.produccion.build.env $ENV_BUILD && chmod 600 $ENV_BUILD"

    local sha; sha="$(git -C "$RAIZ" rev-parse HEAD)"
    local log="$DIST/build-$sha.log"
    mkdir -p "$DIST"
    : > "$log"
    # Un artifact viejo del mismo sha taparia un build que fallo en silencio.
    rm -f "$DIST/wacrm-$sha".*
    cd "$RAIZ"

    # Tipos generados por otra rama: rompen `tsc` aunque el codigo este bien.
    rm -rf "$RAIZ/.next/types"

    if [[ "$sin_pruebas" -eq 0 ]]; then
        npx vitest run >>"$log" 2>&1 || fallo_con_log "vitest" "$log"
        npx tsc --noEmit >>"$log" 2>&1 || fallo_con_log "tsc" "$log"
    fi

    # El lockfile no se toca aqui: se reutiliza node_modules. Si
    # package-lock.json cambio, hay que ejecutar antes `npm ci` en node:20.
    local comun
    comun="$(git -C "$RAIZ" rev-parse --path-format=absolute --git-common-dir)"
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$RAIZ:$RAIZ" -v "$comun:$comun" -w "$RAIZ" \
        -e WACRM_BUILD_ENV="$ENV_BUILD" \
        -e NEXT_PRIVATE_OUTPUT_TRACE_ROOT="$RAIZ" \
        node:20 bash -c 'git config --global --add safe.directory "*"; ./infra/deployment/build-wacrm.sh --sin-tests' \
        >>"$log" 2>&1 || fallo_con_log "el build" "$log"

    [[ -f "$DIST/wacrm-$sha.manifest.json" && -f "$DIST/wacrm-$sha.buildid" ]] \
        || fatal "el build termino pero no dejo el artifact de $sha en $DIST"
    manifiesto_de_produccion "$DIST/wacrm-$sha.manifest.json"

    echo "sha $sha"
    echo "build_id $(cat "$DIST/wacrm-$sha.buildid")"
}

fallo_con_log() {   # $1 que fallo · $2 log
    rojo "ERROR: fallo $1. Log completo: $2"
    tail -30 "$2" | limpiar >&2
    exit 1
}

publicar() {
    local sha="${1:-}"
    [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || fatal "uso: $0 publicar <sha>   (sha hexadecimal)"
    [[ -f "$DIST/wacrm-$sha.tar.gz" ]] \
        || fatal "no hay artifact de $sha en $DIST; compila primero"
    manifiesto_de_produccion "$DIST/wacrm-$sha.manifest.json"

    local rc
    set +e
    bash "$AQUI/desplegar-wacrm-produccion.sh" "$sha" 2>&1 | limpiar
    rc="${PIPESTATUS[0]}"
    set -e
    exit "$rc"
}

servido() {
    local ruta
    ruta="$(ssh ${SSH_OPTS:-} "$HOST_PRODUCCION" "readlink -f $RELEASES_PRODUCCION/current" \
        2> >(grep -v '^\*\*' >&2))" || fatal "no pude preguntar a $HOST_PRODUCCION"
    [[ -n "$ruta" ]] || fatal "$HOST_PRODUCCION no tiene $RELEASES_PRODUCCION/current"
    basename "$ruta"
}

case "${1:-}" in
    compilar) shift; compilar "$@" ;;
    publicar) shift; publicar "$@" ;;
    servido)  servido ;;
    *) fatal "uso: $0 compilar [--sin-pruebas] | publicar <sha> | servido" ;;
esac
