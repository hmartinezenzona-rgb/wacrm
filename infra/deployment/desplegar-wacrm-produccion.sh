#!/usr/bin/env bash
# Publica un artifact en PRODUCCION de forma atomica, con vuelta atras.
#
#   ./infra/deployment/desplegar-wacrm-produccion.sh <sha>
#   ./infra/deployment/desplegar-wacrm-produccion.sh --adoptar   (una sola vez)
#
# POR QUE ESTE SCRIPT Y NO EL DE STAGING CON OTRAS VARIABLES
# ----------------------------------------------------------
# Porque `lib-comun.sh` trae defaults de staging (`HOST_STAGING:=oracle2`,
# `PM2_APP:=wacrm-staging`). Un script que los herede publica en staging cuando
# alguien olvide exportar algo, y eso no avisa: arranca, sirve y responde 200.
# Aqui las constantes son `readonly` y no salen del entorno.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$AQUI/lib-comun.sh"
source "$AQUI/lib-produccion.sh"

SSH_P=(${SSH_OPTS:-} "$HOST_PRODUCCION")
remoto() { ssh "${SSH_P[@]}" "$@"; }

# ─────────────────────────────────────────────────── adopcion (una sola vez)
#
# Hoy produccion es un directorio plano que no es un repositorio, sin releases
# y con `.env.local` DENTRO. Asi no hay a donde volver: la unica copia es la
# que esta sirviendo. Adoptar convierte lo que hay en `release-0` y saca la
# configuracion fuera, sin recompilar nada y sin que el servicio se entere.
if [[ "${1:-}" == "--adoptar" ]]; then
    paso "Adopcion de lo que ya esta sirviendo"
    remoto "test -d $RELEASES_PRODUCCION" \
        && fatal "$RELEASES_PRODUCCION ya existe: la adopcion ya se hizo"
    remoto "test -d $DIRECTORIO_ACTUAL/.next" \
        || fatal "en $DIRECTORIO_ACTUAL no hay un build; no hay nada que adoptar"
    remoto "
        set -e
        mkdir -p $RELEASES_PRODUCCION
        cp -a $DIRECTORIO_ACTUAL $RELEASES_PRODUCCION/release-0
        # La configuracion sale de la release: una release se cambia, las
        # credenciales no. Se COPIA, no se mueve: si algo sale mal, lo que
        # esta sirviendo ahora sigue teniendo su fichero donde siempre.
        test -f $ENV_PRODUCCION || cp -a $DIRECTORIO_ACTUAL/.env.local $ENV_PRODUCCION
        chmod 0600 $ENV_PRODUCCION
        ln -sfn $RELEASES_PRODUCCION/release-0 $RELEASES_PRODUCCION/current
    "
    verde "  $RELEASES_PRODUCCION/release-0 creada desde lo que sirve hoy"
    verde "  $ENV_PRODUCCION con la configuracion, 0600"
    echo
    echo "  Falta UN paso a mano, y es tuyo: apuntar pm2 a"
    echo "      $RELEASES_PRODUCCION/current"
    echo "  y reiniciar. Hasta entonces sigue sirviendo $DIRECTORIO_ACTUAL,"
    echo "  que es exactamente lo que queremos si la adopcion se queda a medias."
    exit 0
fi

SHA="${1:-}"
[[ -n "$SHA" ]] || fatal "uso: $0 <sha>   |   $0 --adoptar"

RAIZ="$(verificar_repo)"
DIST="$RAIZ/dist"
TAR="$DIST/wacrm-$SHA.tar.gz"
[[ -f "$TAR" ]] || fatal "no encuentro $TAR; compila primero"
[[ -f "$DIST/wacrm-$SHA.buildid" ]] || fatal "el artifact no trae su BUILD_ID"
BUILD_ID="$(cat "$DIST/wacrm-$SHA.buildid")"

paso "Artifact"
verde "  commit   $SHA"
verde "  BUILD_ID $BUILD_ID"
( cd "$DIST" && sha256sum -c "wacrm-$SHA.tar.gz.sha256" ) \
    || fatal "el artifact no cuadra con su sha256"

# LOS DOS GUARDAS QUE IMPORTAN.
#
# El nombre del entorno lo escribe quien compila; el project ref dice contra
# que base va a hablar el bundle de verdad. Se exigen los dos, y el segundo NO
# es opcional aqui: un artifact marcado `production` que apunte al Supabase de
# staging pasaria el primero.
verificar_entorno_del_artifact "$DIST/wacrm-$SHA.manifest.json" \
    "$ENTORNO_PRODUCCION" "$PROJECT_REF_PRODUCCION"

# Y que no lleve secretos dentro: el manifiesto viaja y se guarda.
if grep -qiE '"(.*_key|.*secret|.*token|password)"[[:space:]]*:' \
        "$DIST/wacrm-$SHA.manifest.json"; then
    fatal "el manifiesto del artifact contiene algo que parece un secreto.
  Un manifiesto se copia, se archiva y se lee en cualquier sitio."
fi

paso "Estado actual en $HOST_PRODUCCION"
remoto "test -d $RELEASES_PRODUCCION" || fatal \
    "$RELEASES_PRODUCCION no existe: produccion todavia no tiene versiones.
  Ejecuta primero:  $0 --adoptar
  Sin eso no hay release anterior y un despliegue no tendria vuelta atras."
remoto "test -r $ENV_PRODUCCION" || fatal \
    "falta $ENV_PRODUCCION en el host.
  La configuracion vive fuera de la release. Sin ella el proceso arranca sin
  credenciales y el fallo aparece tarde, en la primera peticion a la base."

ANTERIOR="$(remoto "readlink -f $RELEASES_PRODUCCION/current 2>/dev/null || true")"
[[ -n "$ANTERIOR" ]] || fatal "no hay release activa; ejecuta --adoptar"
verde "  release activa  $ANTERIOR"

DESTINO="$RELEASES_PRODUCCION/$SHA"
remoto "test -e $DESTINO" && fatal "$DESTINO ya existe; borra o usa otro sha"

paso "Subiendo la release"
remoto "mkdir -p $DESTINO.parcial"
scp ${SSH_OPTS:-} "$TAR" "$HOST_PRODUCCION:$DESTINO.parcial/release.tar.gz"
remoto "cd $DESTINO.parcial && tar xzf release.tar.gz && rm -f release.tar.gz"

paso "Verificando ANTES de activar"
remoto "
    set -e
    test -f $DESTINO.parcial/.next/BUILD_ID
    test \"\$(cat $DESTINO.parcial/.next/BUILD_ID)\" = '$BUILD_ID'
    test -d $DESTINO.parcial/node_modules
" || fatal "la release subida no es la que se compilo; NO se activa"
# La configuracion se enlaza, no se copia: asi una sola fuente manda y no
# quedan credenciales dentro de cada release archivada.
remoto "ln -sfn $ENV_PRODUCCION $DESTINO.parcial/.env.local"
remoto "mv $DESTINO.parcial $DESTINO"
verde "  release completa y verificada"

paso "Activando"
# El corte es un symlink: instantaneo y reversible. La anterior NO se borra.
remoto "ln -sfn $DESTINO $RELEASES_PRODUCCION/anterior.nueva && \
        ln -sfn $ANTERIOR $RELEASES_PRODUCCION/anterior && \
        rm -f $RELEASES_PRODUCCION/anterior.nueva && \
        ln -sfn $DESTINO $RELEASES_PRODUCCION/current"
remoto "pm2 restart $PM2_APP_PRODUCCION --update-env --time >/dev/null 2>&1"
verde "  current -> $DESTINO"
verde "  anterior -> $ANTERIOR   (no se borra)"

paso "Comprobando lo que se sirve"
# Contra la aplicacion viva, no contra el disco: lo que importa es lo que ve
# un cliente. Y por una ruta que NO esta prerenderizada — ver lib-produccion.sh.
ok=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if build_id_vivo_en_produccion "$BUILD_ID"; then ok=1; break; fi
    sleep 3
done
if [[ -z "$ok" ]]; then
    rojo "  el BUILD_ID $BUILD_ID no responde en $DOMINIO_PRODUCCION"
    echo "  La release anterior sigue en $RELEASES_PRODUCCION/anterior."
    echo "  Vuelve con:  ./infra/deployment/rollback-wacrm-produccion.sh"
    exit 1
fi
verde "  $DOMINIO_PRODUCCION sirve $BUILD_ID"
