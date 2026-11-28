#!/usr/bin/env bash
# Piezas compartidas por build / deploy / rollback.
#
# Se carga con `source`; no se ejecuta suelto. Todo lo que hay aqui son
# comprobaciones que preferimos hacer ANTES de tocar nada, porque el fallo que
# origino estos scripts —compilar en el VPS y tumbarlo— no dio ningun aviso:
# la maquina simplemente dejo de responder.

set -euo pipefail

# ---------------------------------------------------------------- configuracion
: "${HOST_STAGING:=oracle2}"
: "${RELEASES:=/home/ubuntu/wacrm-releases}"
: "${ENV_EXTERNO:=/etc/wacrm-hermes/wacrm.env}"
: "${PM2_APP:=wacrm-staging}"
: "${URL_PUBLICA:=https://crm.onlinefreedom.site}"
: "${PUERTO_LOCAL:=3000}"
# La del VPS. Compilar con otra mayor puede colar sintaxis que alli no arranca.
: "${NODE_MAYOR_ESPERADO:=20}"
#: `LogLevel=ERROR` calla el aviso post-quantum de OpenSSH, que se cuela en
#: la salida de cada llamada y esconde lo que importa.
: "${SSH_OPTS:=-o BatchMode=yes -o ConnectTimeout=20 -o LogLevel=ERROR}"

rojo()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
paso()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

fatal() { rojo "ERROR: $*"; exit 1; }

# ------------------------------------------------------------------ validaciones

#: La raiz del repo, o un fallo. Se busca el `.git` hacia arriba en vez de
#: contar `..`, que es lo que se rompio al pasar a monorepo.
raiz_repo() {
    local d="${1:-$PWD}"
    while [[ "$d" != "/" ]]; do
        [[ -e "$d/.git" ]] && { printf '%s\n' "$d"; return 0; }
        d="$(dirname "$d")"
    done
    return 1
}

verificar_repo() {
    local raiz
    raiz="$(raiz_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")" \
        || fatal "esto no esta dentro de un repositorio git"
    local origen
    origen="$(git -C "$raiz" remote get-url origin 2>/dev/null || echo '')"
    # PORTADO AL REPOSITORIO LEGACY (LEGACY OPTIMIZED V1).
    # En el monorepo esta comprobacion exigia `wacrm-hermes` y rechazaba `wacrm`
    # a secas, porque alli `wacrm` era produccion y no se tocaba desde ese
    # utillaje. Aqui es al reves: este repositorio ES el de produccion, y lo que
    # hay que rechazar es cualquier otro.
    case "$origen" in
        *hmartinezenzona-rgb/wacrm.git|*hmartinezenzona-rgb/wacrm) : ;;
        *wacrm-hermes*) fatal "este es el monorepo, no el repositorio legacy" ;;
        *) fatal "el remoto no es hmartinezenzona-rgb/wacrm sino '${origen:-ninguno}'" ;;
    esac
    printf '%s\n' "$raiz"
}

verificar_arbol_limpio() {
    local raiz="$1"
    [[ -z "$(git -C "$raiz" status --porcelain)" ]] \
        || fatal "hay cambios sin confirmar; un artifact debe corresponder a un commit"
}

verificar_node() {
    command -v node >/dev/null || fatal "no hay node en el PATH"
    local mayor
    mayor="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
    [[ "$mayor" == "$NODE_MAYOR_ESPERADO" ]] \
        || fatal "node v$mayor; se espera la mayor $NODE_MAYOR_ESPERADO (la del VPS)"
}

#: Compilar en oracle2 tumba la maquina: 1 CPU y 952 MB se van a swap y el
#: sshd deja de responder. Paso el 28-ago y costo un reinicio desde la consola
#: de Oracle. El script se niega en vez de confiar en que nadie se equivoque.
verificar_que_no_es_el_vps() {
    local host; host="$(hostname)"
    if [[ -f /home/ubuntu/.pm2/dump.pm2 || "$host" == *oracle* ]]; then
        fatal "esto parece el VPS de staging. NO se compila aqui: usa tu maquina."
    fi
    local memoria_mb
    memoria_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 99999)"
    (( memoria_mb >= 3000 )) \
        || fatal "solo hay ${memoria_mb} MB de RAM; compilar aqui es como compilar en el VPS"
}

# ------------------------------------------------------------------- smoke test

#: Lo que tiene que cumplir una release para darse por buena. Devuelve != 0 si
#: algo falla, para que quien llama decida (deploy revierte, rollback avisa).
#:
#: No basta con "responde 200": eso lo cumple tambien la release ANTERIOR. Por
#: eso se comprueba el BUILD_ID que viaja en el HTML.
#: ¿Se llega siquiera a la maquina desde aqui?
#:
#: Hace falta distinguir dos cosas que se parecen mucho en la salida de curl:
#: "la release nueva no responde" y "se me ha caido la red". El 29-ago un
#: corte de unos segundos por mi lado dio 000 en las cinco comprobaciones, el
#: script lo leyo como release rota y ordeno una vuelta atras — que tampoco
#: pudo ejecutar, porque tampoco llegaba. Revertir a ciegas un despliegue que
#: quizas estaba bien es peor que parar y avisar.
se_llega_al_host() {
    ssh $SSH_OPTS "$HOST_STAGING" true >/dev/null 2>&1
}

smoke() {
    local build_esperado="${1:-}"
    local fallos=0

    local codigo
    codigo="$(ssh $SSH_OPTS "$HOST_STAGING" \
        "curl -s -o /dev/null -m 20 -w '%{http_code}' http://127.0.0.1:${PUERTO_LOCAL}/login" \
        2>/dev/null || echo 000)"
    if [[ "$codigo" == "200" ]]; then
        verde "  /login en el loopback ........ 200"
    else
        rojo  "  /login en el loopback ........ $codigo (se esperaba 200)"; fallos=$((fallos+1))
    fi

    codigo="$(curl -s -o /dev/null -m 25 -w '%{http_code}' "$URL_PUBLICA/login" || echo 000)"
    if [[ "$codigo" == "200" ]]; then
        verde "  /login por el dominio ........ 200"
    else
        rojo  "  /login por el dominio ........ $codigo (se esperaba 200)"; fallos=$((fallos+1))
    fi

    # Las dos puertas del dinero, sin credencial. Un 200 aqui seria un incidente.
    codigo="$(curl -s -o /dev/null -m 25 -w '%{http_code}' \
        "$URL_PUBLICA/api/remesas/deliver?deal_id=humo" || echo 000)"
    if [[ "$codigo" == "401" ]]; then
        verde "  GET  /api/remesas/deliver .... 401"
    else
        rojo  "  GET  /api/remesas/deliver .... $codigo (se esperaba 401)"; fallos=$((fallos+1))
    fi

    codigo="$(curl -s -o /dev/null -m 25 -X POST -H 'content-type: application/json' \
        -d '{"deal_id":"humo"}' -w '%{http_code}' \
        "$URL_PUBLICA/api/remesas/deliver" || echo 000)"
    if [[ "$codigo" == "401" ]]; then
        verde "  POST /api/remesas/deliver .... 401"
    else
        rojo  "  POST /api/remesas/deliver .... $codigo (se esperaba 401)"; fallos=$((fallos+1))
    fi

    if [[ -n "$build_esperado" ]]; then
        if curl -s -m 25 "$URL_PUBLICA/login" | grep -q "$build_esperado"; then
            verde "  build servido ................ $build_esperado"
        else
            rojo  "  build servido ................ NO es $build_esperado"; fallos=$((fallos+1))
        fi
    fi

    return "$fallos"
}

#: El BUILD_ID que hay ahora mismo en `current`, para poder comprobar despues
#: que el restart sirvio de algo.
build_id_activo() {
    ssh $SSH_OPTS "$HOST_STAGING" \
        "cat $RELEASES/current/.next/BUILD_ID 2>/dev/null" 2>/dev/null || true
}

#: El artifact tiene que ser del entorno al que se despliega. Fail closed.
#:
#: Las NEXT_PUBLIC_* van incrustadas en el bundle, asi que un artifact de
#: staging desplegado en produccion NO falla: arranca, sirve paginas y responde
#: 200 contra la base de staging. Los operadores verian un CRM vacio y los
#: clientes no recibirian nada, y nada en los logs diria por que.
#:
#: Por eso no basta con tener cuidado al escribir el comando. Se comprueba.
verificar_entorno_del_artifact() {
    # El tercer argumento es el project ref que se espera. Es OPCIONAL para no
    # romper a quien ya llama con dos, pero en produccion no debe faltar: sin
    # el, un artifact marcado `production` que apunte al Supabase de staging
    # pasa el control, porque el nombre del entorno lo escribe quien compila y
    # el project ref es el que dice contra que base va a hablar de verdad.
    local manifiesto="$1" esperado="$2" ref_esperado="${3:-}"

    [[ -f "$manifiesto" ]] || fatal \
        "el artifact no trae manifiesto ($manifiesto).
  Sin el no se puede saber de que entorno es. Vuelve a compilarlo con un
  build-wacrm.sh que lo escriba; NO lo despliegues a ciegas."

    local entorno ref sha
    entorno="$(sed -nE 's/.*\"environment\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p' "$manifiesto")"
    ref="$(sed -nE 's/.*\"supabase_project_ref\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p' "$manifiesto")"
    sha="$(sed -nE 's/.*\"git_sha\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p' "$manifiesto")"

    [[ -n "$entorno" ]] || fatal "el manifiesto no dice el entorno"

    if [[ "$entorno" != "$esperado" ]]; then
        fatal "ARTIFACT DEL ENTORNO EQUIVOCADO.
  El artifact es de : $entorno
  Se despliega en   : $esperado
  Proyecto Supabase : $ref
  Commit            : $sha

  Esto NO se puede forzar con una variable de entorno, y es a proposito: un
  bundle lleva la base de datos escrita dentro, y desplegarlo en el otro lado
  arranca sin quejarse contra la base que no toca."
    fi
    if [[ -n "$ref_esperado" ]]; then
        [[ -n "$ref" ]] || fatal "el manifiesto no dice el proyecto Supabase.
  Sin el no se puede saber contra que base hablara el bundle."
        if [[ "$ref" != "$ref_esperado" ]]; then
            fatal "ARTIFACT CONTRA LA BASE EQUIVOCADA.
  El artifact apunta a : $ref
  Se despliega contra  : $ref_esperado
  Entorno declarado    : $entorno
  Commit               : $sha

  El nombre del entorno lo escribe quien compila; el project ref dice contra
  que base va a hablar el bundle de verdad. Cuando los dos no coinciden, el que
  manda es el segundo."
        fi
    fi

    verde "  entorno del artifact ... $entorno"
    verde "  proyecto Supabase ..... $ref${ref_esperado:+ (coincide con el esperado)}"
}
