#!/usr/bin/env bash
# Las constantes de PRODUCCION del CRM, y ninguna de staging.
#
# Fichero aparte a proposito. `lib-comun.sh` trae valores por defecto de
# staging (`HOST_STAGING:=oracle2`, `PM2_APP:=wacrm-staging`), y un script de
# produccion que herede esos defaults puede publicar en el sitio equivocado
# cuando alguien olvide exportar una variable. Aqui NO hay `:=`: si algo falta,
# el script se para.
#
# TOPOLOGIA, AUDITADA EL 4-SEP-2026 (solo lectura)
# ------------------------------------------------
#   host                instance-20260709-0825 (129.159.93.221)
#   dominio             wacrm.onlinefreedom.site
#   nginx               proxy_pass http://127.0.0.1:3000
#   pm2                 wacrm
#   directorio          /home/ubuntu/wacrm-deploy   <- NO es un repositorio
#   releases            NO EXISTE
#   node                v20.20.2
#   entorno             /home/ubuntu/wacrm-deploy/.env.local
#   Supabase            hqztotshnlzaiziwjyzh
#
# LO QUE ESO SIGNIFICA
# --------------------
# Produccion no tiene versiones. Hoy no hay a donde volver: la unica copia es
# la que esta sirviendo. Por eso el primer despliegue no es un despliegue, es
# una ADOPCION —ver `--adoptar`—, y hasta que ocurra el script se niega.

set -euo pipefail

HOST_PRODUCCION="${HOST_PRODUCCION:-oracle}"
DOMINIO_PRODUCCION="wacrm.onlinefreedom.site"
PM2_APP_PRODUCCION="wacrm"
RELEASES_PRODUCCION="/home/ubuntu/wacrm-releases"
DIRECTORIO_ACTUAL="/home/ubuntu/wacrm-deploy"
# La configuracion vive FUERA de la release: una release es intercambiable, las
# credenciales no. Hoy esta dentro del directorio y por eso hace falta adoptar.
ENV_PRODUCCION="/home/ubuntu/wacrm.env"
ENTORNO_PRODUCCION="production"
PROJECT_REF_PRODUCCION="hqztotshnlzaiziwjyzh"
UPSTREAM_PRODUCCION="127.0.0.1:3000"

# NO se acepta por variable de entorno. El entorno y el proyecto de una release
# de produccion no son configurables desde la linea de ordenes: si hicieran
# falta otros, es que no es produccion.
readonly DOMINIO_PRODUCCION PM2_APP_PRODUCCION RELEASES_PRODUCCION
readonly DIRECTORIO_ACTUAL ENV_PRODUCCION ENTORNO_PRODUCCION
readonly PROJECT_REF_PRODUCCION UPSTREAM_PRODUCCION

# ---------------------------------------------------------------------------
# El BUILD_ID que se esta sirviendo DE VERDAD.
#
# NO se pregunta a `/login`: esa pagina esta prerenderizada y responde
#     x-nextjs-cache: HIT · Cache-Control: s-maxage=300, stale-while-revalidate=86400
# o sea que puede devolver contenido de hasta 24 h despues de un despliegue.
# Ademas ni siquiera lleva el buildId en su HTML. Medido el 4-sep-2026.
#
# Se pregunta por la EXISTENCIA del bundle de ese BUILD_ID, que sirve el propio
# proceso desde su build y no pasa por la cache de prerenderizado:
#
#     /_next/static/<BUILD_ID>/_ssgManifest.js   200 si esa release esta viva
#                                                404 si no
#
# Es `immutable` y va por BUILD_ID, asi que no puede contestar por otra release.
# Y no necesita sesion: no se debilita la autenticacion para poder mirar.
build_id_vivo_en_produccion() {
    local id="$1"
    local codigo
    codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "https://$DOMINIO_PRODUCCION/_next/static/$id/_ssgManifest.js" || echo 000)"
    [[ "$codigo" == "200" ]]
}
