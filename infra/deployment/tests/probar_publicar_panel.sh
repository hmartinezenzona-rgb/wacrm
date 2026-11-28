#!/usr/bin/env bash
# publicar-panel.sh y panel-local-staging.sh, probados intentando hacerlos mal.
#
# Nada toca produccion ni Docker de verdad: `docker`, `npx`, `ssh` son postizos
# y el repo es uno de mentira en un directorio temporal. Lo que se comprueba es
# que los scripts se NIEGAN donde tienen que negarse y que, en el camino bueno,
# pasan a la orden real lo que deben (el sha, la imagen node:20, el git dir).
set -uo pipefail
cd "$(dirname "$0")/.."
RAIZ_INFRA="$PWD"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fallos=0

# ─── postizos ───────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'FIN'
#!/usr/bin/env bash
# Anota los argumentos y, si se le pide, deja el artifact que dejaria el build.
printf '%s\n' "$*" >> "$TMP_REGISTRO/docker.args"
[[ "${FAKE_DOCKER_RC:-0}" == "0" ]] || { echo "fallo simulado del build"; exit "$FAKE_DOCKER_RC"; }
while [[ $# -gt 0 ]]; do [[ "$1" == "-w" ]] && { w="$2"; break; }; shift; done
sha="$(git -C "$w" rev-parse HEAD)"
mkdir -p "$w/dist"
: > "$w/dist/wacrm-$sha.tar.gz"
echo "BUILDFAKE01" > "$w/dist/wacrm-$sha.buildid"
cat > "$w/dist/wacrm-$sha.manifest.json" <<JSON
{"environment": "${FAKE_ENV:-production}", "git_sha": "$sha", "supabase_project_ref": "${FAKE_REF:-hqztotshnlzaiziwjyzh}"}
JSON
echo "** aviso post-cuantico"
FIN
cat > "$TMP/bin/npx" <<'FIN'
#!/usr/bin/env bash
printf 'npx %s\n' "$*" >> "$TMP_REGISTRO/npx.args"
exit "${FAKE_NPX_RC:-0}"
FIN
cat > "$TMP/bin/ssh" <<'FIN'
#!/usr/bin/env bash
echo "** WARNING: connection is not using a post-quantum key exchange algorithm." >&2
echo "${FAKE_SERVIDO:-/home/ubuntu/wacrm-releases/abc1234def}"
FIN
chmod +x "$TMP/bin"/*
export PATH="$TMP/bin:$PATH"
export TMP_REGISTRO="$TMP"

# ─── un repo de mentira con los scripts dentro ──────────────────────────────
nuevo_repo() {
    REPO="$TMP/repo"; rm -rf "$REPO" "$TMP"/*.args
    mkdir -p "$REPO/infra/deployment" "$REPO/.next/types"
    cp "$RAIZ_INFRA"/{publicar-panel.sh,lib-comun.sh,lib-produccion.sh} "$REPO/infra/deployment/" 2>/dev/null
    # El desplegar postizo solo cuenta con que lo llamaron y con que sha.
    cat > "$REPO/infra/deployment/desplegar-wacrm-produccion.sh" <<'FIN'
#!/usr/bin/env bash
printf 'desplegar %s\n' "$*" > "$TMP_REGISTRO/desplegar.args"
printf '\033[32m  BUILD_ID servido\033[0m\n'
echo "** ruido de ssh" >&2
exit "${FAKE_DESPLEGAR_RC:-0}"
FIN
    printf 'dist/\ninfra/deployment/*.env\n' > "$REPO/.gitignore"
    echo uno > "$REPO/fichero.txt"
    ( cd "$REPO" && git init -q && git add -A && \
      git -c user.name=t -c user.email=t@t commit -qm base )
    echo 'NEXT_PUBLIC_X=1' > "$REPO/infra/deployment/wacrm.produccion.build.env"
    chmod 600 "$REPO/infra/deployment/wacrm.produccion.build.env"
    SHA="$(git -C "$REPO" rev-parse HEAD)"
}

correr() {   # devuelve 0 si el script TERMINO bien; la salida va a $TMP/salida
    ( cd "$REPO" && bash "$REPO/infra/deployment/publicar-panel.sh" "$@" ) >"$TMP/salida" 2>&1
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

dice() {   # $1 nombre · $2 patron que debe estar en la salida
    if grep -qE -- "$2" "$TMP/salida"; then echo "  ok      $1"
    else echo "  FALLO   $1 (no aparece /$2/)"; sed 's/^/            /' "$TMP/salida" | tail -4; fallos=$((fallos+1)); fi
}
nodice() {
    if grep -qE -- "$2" "$TMP/salida"; then
        echo "  FALLO   $1 (aparece /$2/)"; fallos=$((fallos+1))
    else echo "  ok      $1"; fi
}

echo "=== publicar-panel.sh compilar ==="

nuevo_repo
echo dos >> "$REPO/fichero.txt"
probar "arbol con cambios sin confirmar" "RECHAZA" compilar
[[ ! -e "$TMP/docker.args" ]] && echo "  ok      y no llego a compilar" \
    || { echo "  FALLO   compilo con el arbol sucio"; fallos=$((fallos+1)); }

nuevo_repo
touch "$REPO/sin_seguimiento.txt"
probar "un fichero sin seguimiento NO cuenta como sucio" "pasa" compilar --sin-pruebas

nuevo_repo
rm "$REPO/infra/deployment/wacrm.produccion.build.env"
probar "falta el env de build de produccion" "RECHAZA" compilar
dice "y dice de donde copiarlo" "wacrm-worktrees/mejora-legacy"

nuevo_repo
FAKE_ENV=staging probar "el build sale con manifiesto de staging" "RECHAZA" compilar --sin-pruebas
FAKE_ENV=production FAKE_REF=kolppplawzdsjfydwejr probar "production con project ref de staging" "RECHAZA" compilar --sin-pruebas

nuevo_repo
FAKE_DOCKER_RC=3 probar "el build falla" "RECHAZA" compilar --sin-pruebas
dice "y apunta al log" "dist/build-$SHA\.log"
dice "y trae el final del log" "fallo simulado del build"

nuevo_repo
FAKE_NPX_RC=1 probar "las pruebas fallan" "RECHAZA" compilar
[[ ! -e "$TMP/docker.args" ]] && echo "  ok      y no compila con pruebas rotas" \
    || { echo "  FALLO   compilo con pruebas rotas"; fallos=$((fallos+1)); }

nuevo_repo
probar "el camino bueno" "pasa" compilar
dice "imprime el sha" "^sha $SHA\$"
dice "imprime el build_id" "^build_id BUILDFAKE01\$"
nodice "no vuelca el log del build" "aviso post-cuantico"
grep -q "vitest run" "$TMP/npx.args" && grep -q "tsc --noEmit" "$TMP/npx.args" \
    && echo "  ok      corrio vitest y tsc" \
    || { echo "  FALLO   no corrio vitest y tsc"; fallos=$((fallos+1)); }
[[ ! -d "$REPO/.next/types" ]] && echo "  ok      limpio .next/types" \
    || { echo "  FALLO   dejo .next/types"; fallos=$((fallos+1)); }
COMUN="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)"
grep -q -- "-v $COMUN:$COMUN" "$TMP/docker.args" && grep -q "node:20" "$TMP/docker.args" \
    && echo "  ok      docker con node:20 y el git dir comun montado" \
    || { echo "  FALLO   docker sin node:20 o sin el git dir comun"; fallos=$((fallos+1)); }
grep -q -- "--sin-tests" "$TMP/docker.args" \
    && echo "  ok      el build no repite las pruebas" \
    || { echo "  FALLO   el build repite las pruebas"; fallos=$((fallos+1)); }
[[ -f "$REPO/dist/build-$SHA.log" ]] && echo "  ok      deja el log del build" \
    || { echo "  FALLO   sin log"; fallos=$((fallos+1)); }

nuevo_repo
probar "--sin-pruebas" "pasa" compilar --sin-pruebas
[[ ! -e "$TMP/npx.args" ]] && echo "  ok      no corrio vitest ni tsc" \
    || { echo "  FALLO   corrio pruebas con --sin-pruebas"; fallos=$((fallos+1)); }

echo
echo "=== publicar-panel.sh publicar ==="

nuevo_repo
probar "sin sha" "RECHAZA" publicar
probar "sha que no es hexadecimal" "RECHAZA" publicar "../x"
probar "artifact inexistente" "RECHAZA" publicar aaa1111
[[ ! -e "$TMP/desplegar.args" ]] && echo "  ok      y no desplego" \
    || { echo "  FALLO   desplego sin artifact"; fallos=$((fallos+1)); }

mkdir -p "$REPO/dist"
: > "$REPO/dist/wacrm-bbb2222.tar.gz"
echo '{"environment": "staging", "supabase_project_ref": "kolppplawzdsjfydwejr"}' > "$REPO/dist/wacrm-bbb2222.manifest.json"
probar "manifiesto de staging" "RECHAZA" publicar bbb2222
[[ ! -e "$TMP/desplegar.args" ]] && echo "  ok      y no desplego" \
    || { echo "  FALLO   desplego un artifact de staging"; fallos=$((fallos+1)); }

: > "$REPO/dist/wacrm-ccc3333.tar.gz"
echo '{"environment": "production", "supabase_project_ref": "hqztotshnlzaiziwjyzh"}' > "$REPO/dist/wacrm-ccc3333.manifest.json"
probar "artifact de produccion" "pasa" publicar ccc3333
grep -qx "desplegar ccc3333" "$TMP/desplegar.args" \
    && echo "  ok      paso el sha al script de despliegue" \
    || { echo "  FALLO   no paso el sha"; fallos=$((fallos+1)); }
nodice "filtra el ruido de ssh" '^\*\*'
nodice "quita los codigos ANSI" $'\033'
dice "deja pasar la salida util" "BUILD_ID servido"

FAKE_DESPLEGAR_RC=1 probar "propaga el fallo del despliegue" "RECHAZA" publicar ccc3333

echo
echo "=== publicar-panel.sh servido ==="
nuevo_repo
probar "servido" "pasa" servido
dice "imprime el sha servido" "^abc1234def\$"
nodice "filtra el aviso post-cuantico" '^\*\*'

echo
echo "=== panel-local-staging.sh ==="
if HOME="$TMP/sinhome" bash "$RAIZ_INFRA/panel-local-staging.sh" >"$TMP/salida" 2>&1; then
    echo "  FALLO   arranco sin env de staging"; fallos=$((fallos+1))
else echo "  ok      sin ~/.config/wacrm/staging-build.env se niega"; fi
dice "y dice cual falta" "staging-build\.env"

mkdir -p "$TMP/conhome/.config/wacrm"
echo 'NEXT_PUBLIC_SUPABASE_ANON_KEY=SECRETO_NO_IMPRIMIR' > "$TMP/conhome/.config/wacrm/staging-build.env"
cat > "$TMP/bin/npx" <<'FIN'
#!/usr/bin/env bash
echo "npx $* SITE=$NEXT_PUBLIC_SITE_URL KEYSET=${NEXT_PUBLIC_SUPABASE_ANON_KEY:+si}" > "$TMP_REGISTRO/next.args"
FIN
chmod +x "$TMP/bin/npx"
HOME="$TMP/conhome" bash "$RAIZ_INFRA/panel-local-staging.sh" 3111 >"$TMP/salida" 2>&1
grep -q "next dev -p 3111 SITE=http://localhost:3111 KEYSET=si" "$TMP/next.args" \
    && echo "  ok      next dev en el puerto pedido con el env cargado" \
    || { echo "  FALLO   no lanzo next dev bien"; fallos=$((fallos+1)); }
nodice "nunca imprime valores" "SECRETO_NO_IMPRIMIR"

echo
echo "=================================================="
if [[ "$fallos" -eq 0 ]]; then echo "  todo en pie"; else echo "  $fallos FALLOS"; fi
echo "=================================================="
exit "$fallos"
