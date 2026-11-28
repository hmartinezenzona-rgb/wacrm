#!/usr/bin/env bash
# El despliegue de PRODUCCION, probado intentando hacerlo mal.
#
# Nada de esto toca produccion: `ssh`, `scp`, `pm2` y `curl` son postizos y el
# "host remoto" es un directorio temporal. Lo que se comprueba es que el script
# se NIEGA donde tiene que negarse, porque una guarda que nunca se ha visto
# decir que no es una suposicion.
set -uo pipefail
cd "$(dirname "$0")/.."
RAIZ_INFRA="$PWD"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fallos=0

# ─── postizos ───────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin" "$TMP/remoto"
cat > "$TMP/bin/ssh" <<'FIN'
#!/usr/bin/env bash
# La orden remota es SIEMPRE el ultimo argumento; lo de antes es host y flags.
# Se traduce /home/ubuntu al directorio temporal que hace de "host".
orden="${!#}"
bash -c "${orden//\/home\/ubuntu/$REMOTO}"
FIN
cat > "$TMP/bin/scp" <<'FIN'
#!/usr/bin/env bash
# Por posicion, no por forma: `-o BatchMode=yes` mete un argumento sin guion
# que no es ni origen ni destino. El destino es el ultimo y el origen el previo.
n=$#; destino="${!n}"; p=$((n-1)); origen="${!p}"
ruta="${destino#*:}"; ruta="${ruta//\/home\/ubuntu/$REMOTO}"
mkdir -p "$(dirname "$ruta")"; cp "$origen" "$ruta"
FIN
cat > "$TMP/bin/pm2" <<'FIN'
#!/usr/bin/env bash
echo "$*" >> "$REMOTO/pm2.log"
FIN
printf '#!/usr/bin/env bash\nprintf %%s "${CURL_CODE:-200}"\n' > "$TMP/bin/curl"
chmod +x "$TMP/bin"/*
export PATH="$TMP/bin:$PATH"
export REMOTO="$TMP/remoto"
export SSH_OPTS=""

# ─── un repo de mentira con su artifact ─────────────────────────────────────
# `verificar_repo` saca la raiz de donde vive el script, asi que los artifacts
# tienen que ir al dist DE VERDAD. Se limpian al salir.
REPO="$(cd "$RAIZ_INFRA/../.." && pwd)"
mkdir -p "$REPO/dist"
trap 'rm -rf "$TMP" "$REPO"/dist/wacrm-{aaa1111,bbb2222,ccc3333,ddd4444,eee5555,fff6666,999cafe,888dead}.*' EXIT
artifact() {   # $1 entorno · $2 project_ref · $3 build_id · $4 sha
    local sha="$4"
    mkdir -p "$TMP/build/.next" "$TMP/build/node_modules"
    echo "$3" > "$TMP/build/.next/BUILD_ID"
    ( cd "$TMP/build" && tar czf "$REPO/dist/wacrm-$sha.tar.gz" . )
    ( cd "$REPO/dist" && sha256sum "wacrm-$sha.tar.gz" > "wacrm-$sha.tar.gz.sha256" )
    echo "$3" > "$REPO/dist/wacrm-$sha.buildid"
    cat > "$REPO/dist/wacrm-$sha.manifest.json" <<FIN
{"environment": "$1", "git_sha": "$sha", "supabase_project_ref": "$2"}
FIN
}

correr() {   # devuelve 0 si el script TERMINO bien
    ( cd "$RAIZ_INFRA/.." && \
      bash "$RAIZ_INFRA/desplegar-wacrm-produccion.sh" "$@" ) \
      >"$TMP/salida" 2>&1
}

probar() {   # $1 nombre · $2 se_espera(pasa|RECHAZA) · resto args
    local nombre="$1" esperado="$2"; shift 2
    if correr "$@"; then real="pasa"; else real="RECHAZA"; fi
    if [[ "$real" == "$esperado" ]]; then
        echo "  ok      $nombre  ($real)"
    else
        echo "  FALLO   $nombre  (esperaba $esperado, dio $real)"
        sed 's/^/            /' "$TMP/salida" | tail -4
        fallos=$((fallos+1))
    fi
}

echo "=== el despliegue de produccion ==="

# 1 · sin infraestructura de releases no se despliega: no habria vuelta atras
rm -rf "$REMOTO/wacrm-releases"
artifact production hqztotshnlzaiziwjyzh IDBUENO000 aaa1111
probar "sin releases en el host, se niega" "RECHAZA" aaa1111
grep -q "adoptar" "$TMP/salida" \
    && echo "  ok      y explica que hay que adoptar primero" \
    || { echo "  FALLO   no dice como salir del paso"; fallos=$((fallos+1)); }

# a partir de aqui, el host ya tiene releases y configuracion
mkdir -p "$REMOTO/wacrm-releases/release-0/.next"
echo VIEJO0000 > "$REMOTO/wacrm-releases/release-0/.next/BUILD_ID"
ln -sfn "$REMOTO/wacrm-releases/release-0" "$REMOTO/wacrm-releases/current"
touch "$REMOTO/wacrm.env"

# 2 · el artifact de STAGING en produccion
artifact staging kolppplawzdsjfydwejr IDBUENO000 bbb2222
probar "artifact de staging en PRODUCCION" "RECHAZA" bbb2222

# 3 · marcado production pero apuntando a otra base
artifact production kolppplawzdsjfydwejr IDBUENO000 ccc3333
probar "production con project ref de staging" "RECHAZA" ccc3333

# 4 · el tar no cuadra con su sha256
artifact production hqztotshnlzaiziwjyzh IDBUENO000 ddd4444
echo "estropeado" >> "$REPO/dist/wacrm-ddd4444.tar.gz"
probar "el artifact no cuadra con su sha256" "RECHAZA" ddd4444

# 5 · el BUILD_ID del tar no es el que dice el artifact
artifact production hqztotshnlzaiziwjyzh IDBUENO000 eee5555
echo OTRODISTINTO > "$REPO/dist/wacrm-eee5555.buildid"
probar "el BUILD_ID del tar no es el declarado" "RECHAZA" eee5555

# 6 · el manifiesto lleva algo que parece un secreto
artifact production hqztotshnlzaiziwjyzh IDBUENO000 fff6666
cat > "$REPO/dist/wacrm-fff6666.manifest.json" <<FIN
{"environment":"production","git_sha":"fff6666","supabase_project_ref":"hqztotshnlzaiziwjyzh","service_role_key":"algo"}
FIN
probar "manifiesto con pinta de secreto" "RECHAZA" fff6666

# 7 · el bueno, y lo sirve
artifact production hqztotshnlzaiziwjyzh IDBUENO000 999cafe
probar "el artifact correcto se despliega" "pasa" 999cafe
[[ "$(readlink -f "$REMOTO/wacrm-releases/current")" == "$REMOTO/wacrm-releases/999cafe" ]] \
    && echo "  ok      current apunta a la release nueva" \
    || { echo "  FALLO   current no cambio"; fallos=$((fallos+1)); }
[[ -d "$REMOTO/wacrm-releases/release-0" ]] \
    && echo "  ok      la anterior NO se borro" \
    || { echo "  FALLO   se perdio la release anterior"; fallos=$((fallos+1)); }

# 8 · el dominio no sirve ese BUILD_ID -> no se da por bueno
artifact production hqztotshnlzaiziwjyzh IDBUENO000 888dead
CURL_CODE=404 probar "si el dominio no sirve ese BUILD_ID, falla" "RECHAZA" 888dead

# 9 · sin defaults de staging
echo
echo "=== las constantes de produccion ==="
if grep -vE '^[[:space:]]*#' "$RAIZ_INFRA/lib-produccion.sh" \
     | grep -qE ':=|HOST_STAGING|wacrm-staging'; then
    echo "  FALLO   lib-produccion.sh tiene defaults o nombres de staging"
    fallos=$((fallos+1))
else
    echo "  ok      ni un solo default ni nombre de staging"
fi
grep -q 'readonly' "$RAIZ_INFRA/lib-produccion.sh" \
    && echo "  ok      las constantes son readonly" \
    || { echo "  FALLO   se pueden pisar desde el entorno"; fallos=$((fallos+1)); }
grep -q '_ssgManifest' "$RAIZ_INFRA/lib-produccion.sh" \
    && echo "  ok      el BUILD_ID no se pregunta a una pagina prerenderizada" \
    || { echo "  FALLO   el BUILD_ID se comprueba de forma cacheable"; fallos=$((fallos+1)); }

echo
echo "=== el rollback ==="
rm -f "$REMOTO/wacrm-releases/anterior"
( cd "$RAIZ_INFRA/.." && bash "$RAIZ_INFRA/rollback-wacrm-produccion.sh" ) >"$TMP/salida" 2>&1 \
    && { echo "  FALLO   volvio sin saber a donde"; fallos=$((fallos+1)); } \
    || echo "  ok      sin marca 'anterior' no adivina, pregunta"

ln -sfn "$REMOTO/wacrm-releases/release-0" "$REMOTO/wacrm-releases/anterior"
if ( cd "$RAIZ_INFRA/.." && bash "$RAIZ_INFRA/rollback-wacrm-produccion.sh" ) >"$TMP/salida" 2>&1; then
    echo "  ok      vuelve a la anterior"
    [[ -d "$REMOTO/wacrm-releases/999cafe" ]] \
        && echo "  ok      la release mala NO se borro: se puede volver" \
        || { echo "  FALLO   se borro de la que se venia"; fallos=$((fallos+1)); }
else
    echo "  FALLO   el rollback no funciono"; sed 's/^/            /' "$TMP/salida" | tail -4
    fallos=$((fallos+1))
fi
grep -vE '^[[:space:]]*#' "$RAIZ_INFRA/rollback-wacrm-produccion.sh" \
    | grep -qE '(^|[^a-z])(tar |scp |npm |next build)' \
    && { echo "  FALLO   el rollback recompila o sube algo"; fallos=$((fallos+1)); } \
    || echo "  ok      el rollback no compila ni sube nada"

echo
echo "=================================================="
if [[ "$fallos" -eq 0 ]]; then echo "  todo en pie"; else echo "  $fallos FALLOS"; fi
echo "=================================================="
exit "$fallos"
