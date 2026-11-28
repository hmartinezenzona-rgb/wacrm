#!/usr/bin/env bash
# Compila WaCRM y deja un artifact listo para subir.
#
# FUERA del VPS, siempre. El script se niega a correr en oracle2 (ver
# `verificar_que_no_es_el_vps`): `next build` alli agota la memoria, la maquina
# se va a swap y el sshd deja de responder.
#
#   ./infra/deployment/build-wacrm.sh [--sin-tests]
#
# Deja: dist/wacrm-<sha>.tar.gz  +  dist/wacrm-<sha>.sha256

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-comun.sh"

SIN_TESTS=0
[[ "${1:-}" == "--sin-tests" ]] && SIN_TESTS=1

paso "Comprobaciones previas"
verificar_que_no_es_el_vps
RAIZ="$(verificar_repo)"
verificar_arbol_limpio "$RAIZ"
verificar_node
SHA="$(git -C "$RAIZ" rev-parse HEAD)"
RAMA="$(git -C "$RAIZ" rev-parse --abbrev-ref HEAD)"
verde "  repo   $RAIZ"
verde "  rama   $RAMA"
verde "  commit $SHA"
verde "  node   $(node --version)"

# En el repositorio legacy la aplicacion vive en la RAIZ (no hay monorepo).
APP="$RAIZ"
[[ -f "$APP/next.config.ts" ]] || fatal "no encuentro next.config.ts en la raiz del repo"

paso "Configuracion de compilacion"
# Las NEXT_PUBLIC_* se INCRUSTAN en el bundle. Sin ellas el build se cae en el
# prerender ("Your project's URL and API key are required"), y peor: si se
# cuelan las de otro entorno, el artifact apunta a la base equivocada sin que
# nada lo avise. Por eso se exige el fichero en vez de dejarlo al azar de lo
# que hubiera en .env.local.
: "${WACRM_BUILD_ENV:=$RAIZ/infra/deployment/wacrm.build.env}"
[[ -f "$WACRM_BUILD_ENV" ]] \
    || fatal "falta $WACRM_BUILD_ENV (ver wacrm.build.env.example)"
faltan=""
for v in NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_ANON_KEY NEXT_PUBLIC_SITE_URL; do
    grep -qE "^$v=.+" "$WACRM_BUILD_ENV" || faltan="$faltan $v"
done
[[ -z "$faltan" ]] || fatal "en $WACRM_BUILD_ENV faltan valores:$faltan"
verde "  $WACRM_BUILD_ENV"
verde "  destino  $(grep -E '^NEXT_PUBLIC_SUPABASE_URL=' "$WACRM_BUILD_ENV" | cut -d= -f2-)"

# QUE ENTORNO ES ESTE ARTIFACT.
#
# Las NEXT_PUBLIC_* se incrustan en el bundle, asi que el artifact de staging y
# el de produccion NO son el mismo binario con distinta configuracion: son dos
# cosas distintas. Y uno desplegado en el sitio del otro no falla — arranca,
# sirve paginas y responde 200 apuntando a la base equivocada. El error se
# descubre mirando los datos, que es tarde.
#
# Por eso el artifact lleva escrito de donde es, y el despliegue lo comprueba.
ENTORNO="$(grep -E '^WACRM_ENVIRONMENT=' "$WACRM_BUILD_ENV" | cut -d= -f2- | tr -d '\r')"
[[ -n "$ENTORNO" ]] \
    || fatal "falta WACRM_ENVIRONMENT en $WACRM_BUILD_ENV: sin eso el artifact
  no dice a que entorno pertenece y cualquiera puede desplegarlo en el otro"
case "$ENTORNO" in
    staging|production) ;;
    *) fatal "WACRM_ENVIRONMENT=$ENTORNO no es ni staging ni production" ;;
esac
# El project-ref sale de la URL, que es lo que de verdad se incrusta. Asi el
# manifiesto no puede mentir sobre a que base apunta el bundle.
PROJECT_REF="$(grep -E '^NEXT_PUBLIC_SUPABASE_URL=' "$WACRM_BUILD_ENV" \
    | sed -E 's|.*//([^.]+)\..*|\1|')"
verde "  entorno  $ENTORNO"
verde "  proyecto $PROJECT_REF"
cp "$WACRM_BUILD_ENV" "$APP/.env.local"
# Que no se quede ahi si el build peta a mitad.
trap 'rm -f "$APP/.env.local"' EXIT

paso "Dependencias (npm ci)"
( cd "$APP" && npm ci --no-audit --no-fund )

if (( SIN_TESTS == 0 )); then
    # Lo minimo que no se salta: si el modulo de entrega esta roto, no hay
    # artifact. El resto de la suite es de la fase de pruebas, no de esta.
    paso "Tests de la ruta del dinero"
    ( cd "$APP" && npx vitest run src/lib/pipelines/ )
else
    rojo "  AVISO: --sin-tests; el artifact no esta respaldado por la suite"
fi

paso "Compilando"
# `next build` valida TypeScript en Next 16; un error de tipos para aqui.
( cd "$APP" && npx next build )

paso "Armando el standalone"
STANDALONE="$APP/.next/standalone"
[[ -d "$STANDALONE" ]] || fatal "no hay .next/standalone (falta output:'standalone'?)"
# El standalone no trae ni los estaticos ni public: hay que meterlos dentro o
# la pagina sale sin CSS y sin imagenes.
rm -rf "$STANDALONE/.next/static" "$STANDALONE/public"
cp -r "$APP/.next/static" "$STANDALONE/.next/static"
[[ -d "$APP/public" ]] && cp -r "$APP/public" "$STANDALONE/public"

# Ningun secreto viaja dentro del artifact: la configuracion vive fuera de la
# release, en el host. Si el build dejo un .env, se queda aqui.
find "$STANDALONE" -maxdepth 1 -name '.env*' -print -delete

BUILD_ID="$(cat "$APP/.next/BUILD_ID")"
verde "  BUILD_ID $BUILD_ID"

paso "Empaquetando"
DIST="$RAIZ/dist"
mkdir -p "$DIST"
TAR="$DIST/wacrm-$SHA.tar.gz"
# `--sort=name` y fecha fija: dos builds del mismo commit dan el mismo tar.
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -czf "$TAR" -C "$STANDALONE" .
( cd "$DIST" && sha256sum "$(basename "$TAR")" > "$(basename "$TAR").sha256" )

printf '%s\n' "$SHA"      > "$DIST/wacrm-$SHA.commit"
printf '%s\n' "$BUILD_ID" > "$DIST/wacrm-$SHA.buildid"

paso "Manifiesto del artifact"
cat > "$DIST/wacrm-$SHA.manifest.json" <<MANIFIESTO
{
  "environment": "$ENTORNO",
  "git_sha": "$SHA",
  "build_id": "$BUILD_ID",
  "supabase_project_ref": "$PROJECT_REF",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
MANIFIESTO
verde "  $DIST/wacrm-$SHA.manifest.json"


paso "Listo"
verde "  $TAR"
verde "  $(du -h "$TAR" | cut -f1)"
echo
echo "  Desplegar con:"
echo "    ./infra/deployment/deploy-wacrm-staging.sh $SHA"
