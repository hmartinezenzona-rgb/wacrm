#!/usr/bin/env bash
# staging-migracion.sh y produccion-migracion.sh, probados intentando hacerlos mal.
#
# Nada toca produccion, la red ni Docker de verdad: `docker` y `curl` son postizos
# y el repo es uno de mentira en un directorio temporal. Lo que se comprueba es
# que los scripts se NIEGAN donde tienen que negarse y que, en el camino bueno,
# mandan a la base lo que deben (y NO mandan lo que no deben).
set -uo pipefail
cd "$(dirname "$0")/.."
RAIZ_DB="$PWD"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fallos=0
export TMPDIR="$TMP/tmpdir"; mkdir -p "$TMPDIR"

# ─── postizos ───────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'FIN'
#!/usr/bin/env bash
# Guarda el SQL que le llega por stdin (uno por llamada) y contesta segun marcas.
mkdir "$TMP_REGISTRO/lock" 2>/dev/null || { echo "docker en paralelo"; exit 99; }
trap 'rmdir "$TMP_REGISTRO/lock"' EXIT
mkdir -p "$TMP_REGISTRO/sql"
n=$(ls "$TMP_REGISTRO/sql" | wc -l); n=$((n+1))
f="$TMP_REGISTRO/sql/$(printf '%03d' "$n").sql"
cat > "$f"
printf '%s\n' "$*" >> "$TMP_REGISTRO/docker.args"
if grep -q 'INVENTARIO' "$f"; then
    [[ -f "$TMP_REGISTRO/stg_rows.tsv" ]] && cat "$TMP_REGISTRO/stg_rows.tsv"; exit 0
fi
if grep -q 'FAKE_MIG_ERROR' "$f"; then
    echo "psql:<stdin>:3: ERROR:  syntax error at or near \"boom\""; exit 3
fi
if grep -q 'ALL_PASS_OK' "$f"; then
    echo "psql:<stdin>:9: ERROR:  ALL PASS (rolled back on purpose)"; exit 3
fi
if grep -q 'ASSERT_FALLA' "$f"; then
    echo "psql:<stdin>:9: ERROR:  cosa: 1 expectation(s) FAILED"; exit 3
fi
if grep -q 'ERR_UNLESS_MIG' "$f" && ! grep -q 'MIGRATED_MARK' "$f"; then
    echo "psql:<stdin>:5: ERROR:  falta la funcion base"; exit 3
fi
if grep -q 'ERR_UUID' "$f"; then
    u=$(printf '%08x' "$n")
    echo "psql:<stdin>:5: ERROR:  fila $u-1111-2222-3333-444444444444 mala"; exit 3
fi
if grep -q 'pg_get_functiondef' "$f"; then
    if [[ "${FAKE_ROLLBACK_DIFF:-0}" == 1 ]] && grep -q 'ROLLBACK_MARK' "$f"; then
        echo "fn_a|cccccccccccc00000000|{postgres=X/postgres}"
    else
        echo "fn_a|aaaaaaaaaaaa00000000|{postgres=X/postgres}"
    fi
    echo "fn_b|bbbbbbbbbbbb00000000|"
fi
exit 0
FIN

cat > "$TMP/bin/curl" <<'FIN'
#!/usr/bin/env bash
# Postizo de curl: apunta lo que se le pide y contesta segun la URL y el cuerpo.
printf '%s\n' "$*" >> "$TMP_REGISTRO/curl.args"
out=""; body=""; prev=""; url=""
for a in "$@"; do
    case "$prev" in -o) out="$a" ;; --data-binary) body="${a#@}" ;; -K) cfg="$a" ;; esac
    prev="$a"; url="$a"
done
mkdir -p "$TMP_REGISTRO/api"
n=$(ls "$TMP_REGISTRO/api" | wc -l); n=$((n+1))
cp "$body" "$TMP_REGISTRO/api/$(printf '%03d' "$n").json" 2>/dev/null
[[ -n "${cfg:-}" ]] && grep -q 'Bearer ' "$cfg" && echo "auth" >> "$TMP_REGISTRO/curl.auth"
respuesta() { printf '%s' "$2" > "$out"; printf '%s' "$1"; exit 0; }
if [[ "$url" == */database/migrations ]]; then
    grep -q 'BOOM' "$body" && respuesta 400 '{"message":"boom: syntax error at or near BOOM"}'
    respuesta 201 '[]'
fi
if grep -q 'INVENTARIO' "$body"; then
    jq -Rn '[inputs | {r: .}]' < "$TMP_REGISTRO/prod_rows.tsv" > "$TMP_REGISTRO/inv.json" 2>/dev/null || echo '[]' > "$TMP_REGISTRO/inv.json"
    respuesta 201 "$(cat "$TMP_REGISTRO/inv.json")"
fi
if grep -q 'select version' "$body"; then respuesta 201 '[{"version":"20261021000000"}]'; fi
if grep -q 'schema_migrations' "$body"; then respuesta 201 "${FAKE_RECORDED:-[]}"; fi
respuesta 201 '[]'
FIN
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export TMP_REGISTRO="$TMP"

# ─── un repo de mentira con los scripts dentro ──────────────────────────────
nuevo_repo() {
    REPO="$TMP/repo"; rm -rf "$REPO" "$TMP/sql" "$TMP/api" "$TMP"/*.args "$TMPDIR"/*
    mkdir -p "$REPO/infra/db" "$REPO/supabase/migrations" "$REPO/supabase/staging/assertions"
    cp "$RAIZ_DB"/*.sh "$RAIZ_DB"/*.py "$REPO/infra/db/" 2>/dev/null
    echo 'CRM_STAGING_DATABASE_URL=postgres://falso' > "$REPO/.env.staging"
    M="$REPO/supabase/migrations"; A="$REPO/supabase/staging/assertions"
    printf -- '-- MIGRATED_MARK\nCREATE FUNCTION fn_a() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;\n' > "$M/900_prueba.sql"
    printf -- '-- ROLLBACK_MARK\nDROP FUNCTION fn_a();\n' > "$M/ROLLBACK-900-prueba.sql"
    printf '\\set ON_ERROR_STOP on\n-- ALL_PASS_OK\nBEGIN;\nSELECT 1;\nROLLBACK;\n' > "$A/prueba.sql"
    # para produccion: dos migraciones que se encadenan y un HOME con el token
    printf -- '-- 900 MIGRATED_MARK\nCREATE OR REPLACE FUNCTION public.fn_a() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;\n' > "$M/900_prueba.sql"
    printf -- '-- 901\nCREATE OR REPLACE FUNCTION public.fn_b(x int) RETURNS int LANGUAGE sql AS $$ SELECT x $$;\nALTER TABLE public.tabla_t ADD COLUMN IF NOT EXISTS c int;\n' > "$M/901_segunda.sql"
    printf -- '-- ROLLBACK_MARK_900\nDROP FUNCTION public.fn_a();\n' > "$M/ROLLBACK-900-prueba.sql"
    printf -- '-- ROLLBACK_MARK_901\nDROP FUNCTION public.fn_b(int);\n' > "$M/ROLLBACK-901-segunda.sql"
    export HOME="$TMP/home"; rm -rf "$HOME"; mkdir -p "$HOME/.config/wacrm"
    echo 'SUPABASE_ACCESS_TOKEN=TOKEN_SECRETO_123' > "$HOME/.config/wacrm/supabase-token.env"
    chmod 600 "$HOME/.config/wacrm/supabase-token.env"
    rm -f "$TMP/stg_rows.tsv" "$TMP/prod_rows.tsv" "$TMP/curl.auth"
    unset FAKE_RECORDED
}

correr() {   # $1 script (staging|produccion) · resto args. La salida va a $TMP/salida
    local s="$1"; shift
    ( cd "$REPO" && bash "$REPO/infra/db/$s-migracion.sh" "$@" ) >"$TMP/salida" 2>&1
}

probar() {   # $1 nombre · $2 se_espera(pasa|RECHAZA) · $3 script · resto args
    local nombre="$1" esperado="$2" s="$3"; shift 3
    if correr "$s" "$@"; then real="pasa"; else real="RECHAZA"; fi
    if [[ "$real" == "$esperado" ]]; then
        echo "  ok      $nombre  ($real)"
    else
        echo "  FALLO   $nombre  (esperaba $esperado, dio $real)"
        sed 's/^/            /' "$TMP/salida" | tail -6
        fallos=$((fallos+1))
    fi
}

dice() {   # $1 nombre · $2 patron que debe estar en la salida
    if grep -qE -- "$2" "$TMP/salida"; then echo "  ok      $1"
    else echo "  FALLO   $1 (no aparece /$2/)"; sed 's/^/            /' "$TMP/salida" | tail -6; fallos=$((fallos+1)); fi
}
nodice() {
    if grep -qE -- "$2" "$TMP/salida"; then
        echo "  FALLO   $1 (aparece /$2/)"; fallos=$((fallos+1))
    else echo "  ok      $1"; fi
}
cierto() {   # $1 nombre · resto: comando que debe salir bien
    local n="$1"; shift
    if "$@"; then echo "  ok      $n"; else echo "  FALLO   $n"; fallos=$((fallos+1)); fi
}
enviados() { ls "$TMP/api" 2>/dev/null | wc -l; }
fila() {   # $1 kind · $2 key · $3 md5 · $4 md5 normalizado · $5 cuerpo
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | base64 -w0)"
}
sql_enviado() { cat "$TMP"/sql/*.sql 2>/dev/null; }
sin_commit() { ! grep -q '^COMMIT;' <(sql_enviado); }
con_commit() { grep -q '^COMMIT;' <(sql_enviado); }

echo "=== staging-migracion.sh aplicar ==="

nuevo_repo
probar "camino bueno" "pasa" staging aplicar "$M/900_prueba.sql" "$A/prueba.sql" "$M/ROLLBACK-900-prueba.sql" fn_a,fn_b
dice "dry-run OK" "^dry-run +OK"
dice "apply OK" "^apply +OK"
dice "assertion OK" "^assertion +OK"
dice "rollback OK" "^rollback +OK"
dice "imprime md5 de las funciones" "fn_a +aaaaaaaaaaaa"
cierto "hizo COMMIT" con_commit
ultimo=$(ls "$TMP/sql" | tail -1)
cierto "la prueba de rollback termina en ROLLBACK" bash -c "tail -n1 '$TMP/sql/$ultimo' | grep -qx 'ROLLBACK;'"
cierto "usa postgres:17 con el env de staging" grep -q -- '--env-file .env.staging postgres:17' "$TMP/docker.args"

nuevo_repo
printf '\\set ON_ERROR_STOP on\n-- ASSERT_FALLA\nSELECT 1;\n' > "$A/prueba.sql"
probar "el dry run falla" "RECHAZA" staging aplicar "$M/900_prueba.sql" "$A/prueba.sql" "$M/ROLLBACK-900-prueba.sql" fn_a
dice "dry-run FAIL con la primera linea ERROR" "^dry-run +FAIL.*FAILED"
dice "apunta al log" "log: .*\.log"
cierto "NO aplico (ningun COMMIT)" sin_commit

nuevo_repo
echo '-- FAKE_MIG_ERROR' >> "$M/900_prueba.sql"
probar "la migracion revienta en el dry run" "RECHAZA" staging aplicar "$M/900_prueba.sql" "$A/prueba.sql" "$M/ROLLBACK-900-prueba.sql"
cierto "NO aplico" sin_commit

nuevo_repo
FAKE_ROLLBACK_DIFF=1 probar "el rollback no devuelve el md5 previo" "RECHAZA" staging aplicar "$M/900_prueba.sql" "$A/prueba.sql" "$M/ROLLBACK-900-prueba.sql" fn_a
dice "lo dice" "^rollback +FAIL"

nuevo_repo
probar "faltan argumentos" "RECHAZA" staging aplicar "$M/900_prueba.sql"
probar "fichero inexistente" "RECHAZA" staging aplicar "$M/no.sql" "$A/prueba.sql" "$M/ROLLBACK-900-prueba.sql"
rm "$REPO/.env.staging"
probar "sin .env.staging" "RECHAZA" staging aplicar "$M/900_prueba.sql" "$A/prueba.sql" "$M/ROLLBACK-900-prueba.sql"
cierto "y no llamo a docker" test ! -e "$TMP/docker.args"

echo
echo "=== staging-migracion.sh relacionadas ==="

nuevo_repo
printf '\\set ON_ERROR_STOP on\n-- foo ERR_UNLESS_MIG\n' > "$A/foo-b.sql"
printf '\\set ON_ERROR_STOP on\n-- foo ERR_UUID\n' > "$A/foo-c.sql"
printf '\\set ON_ERROR_STOP on\n-- foo ALL_PASS_OK\n' > "$A/foo-a.sql"
printf '\\set ON_ERROR_STOP on\n-- otra cosa ALL_PASS_OK\n' > "$A/zzz-no.sql"
probar "relacionadas por patron (hay un DIFF)" "RECHAZA" staging relacionadas "$M/900_prueba.sql" foo
dice "SAME cuando ambos dan igual" "^SAME \| foo-a \|"
dice "DIFF cuando la migracion cambia el resultado" "^DIFF \| foo-b \| base: ERROR: +falta la funcion base \| mig: ERROR: +ALL PASS|^DIFF \| foo-b \|"
dice "SAME aunque cambien los uuid" "^SAME \| foo-c \|"
nodice "no toca lo que no coincide con el patron" "zzz-no"
dice "totales" "TOTAL 3 \| SAME 2 \| DIFF 1"

nuevo_repo
printf '\\set ON_ERROR_STOP on\n-- foo ALL_PASS_OK\n' > "$A/foo-a.sql"
printf '\\set ON_ERROR_STOP on\n-- foo ALL_PASS_OK\n' > "$A/foo-skip.sql"
probar "salta la asercion indicada" "pasa" staging relacionadas "$M/900_prueba.sql" foo foo-skip
nodice "sin la saltada" "foo-skip"

nuevo_repo
printf '\\set ON_ERROR_STOP on\n-- foo ALL_PASS_OK\n' > "$A/foo-a.sql"
probar "ya aplicada: la base arranca con el ROLLBACK" "pasa" staging relacionadas "$M/900_prueba.sql" foo --ya-aplicada "$M/ROLLBACK-900-prueba.sql"
base=$(ls "$TMP/sql" | sed -n 1p); mig=$(ls "$TMP/sql" | sed -n 2p)
cierto "la base lleva el rollback y no la migracion" bash -c "grep -q ROLLBACK_MARK '$TMP/sql/$base' && ! grep -q MIGRATED_MARK '$TMP/sql/$base'"
cierto "la otra va rollback, migracion, aserto (en ese orden)" bash -c "grep -o -E 'ROLLBACK_MARK|MIGRATED_MARK|ALL_PASS_OK' '$TMP/sql/$mig' | tr '\n' ' ' | grep -q 'ROLLBACK_MARK MIGRATED_MARK ALL_PASS_OK'"

nuevo_repo
probar "ya aplicada sin el fichero rollback" "RECHAZA" staging relacionadas "$M/900_prueba.sql" foo --ya-aplicada

echo
echo "=== produccion-migracion.sh: el token ==="

nuevo_repo
rm "$HOME/.config/wacrm/supabase-token.env"
for c in aplicar verificar; do
    probar "$c sin fichero de token" "RECHAZA" produccion $c "$M/900_prueba.sql"
done
dice "dice donde tiene que estar" "supabase-token\.env"
cierto "y no llamo a la red" test ! -e "$TMP/curl.args"

nuevo_repo
chmod 644 "$HOME/.config/wacrm/supabase-token.env"
probar "aplicar con el token en 0644" "RECHAZA" produccion aplicar "$M/900_prueba.sql"
dice "pide 600" "600"
nodice "no imprime el token" "TOKEN_SECRETO_123"
cierto "y no llamo a la red" test ! -e "$TMP/curl.args"
probar "previa con el token en 0644" "RECHAZA" produccion previa "$M/900_prueba.sql"
probar "verificar con el token en 0640" "RECHAZA" produccion verificar "$M/900_prueba.sql"

echo
echo "=== produccion-migracion.sh previa ==="

nuevo_repo
FAKE_RECORDED='[{"name":"900_prueba"}]' probar "previa con un nombre ya registrado" "RECHAZA" produccion previa "$M/900_prueba.sql" "$M/901_segunda.sql"
dice "dice RECORDED y el nombre" "RECORDED.*900_prueba"
cierto "y no toco staging" test ! -e "$TMP/docker.args"

nuevo_repo
fila fn 'public.fn_a()' m1 n1 'cuerpo a' > "$TMP/stg_rows.tsv"; cp "$TMP/stg_rows.tsv" "$TMP/prod_rows.tsv"
fila fn 'public.fn_b(integer)' m2 n2 'cuerpo b' >> "$TMP/stg_rows.tsv"; fila fn 'public.fn_b(integer)' m2 n2 'cuerpo b' >> "$TMP/prod_rows.tsv"
probar "previa con todo igual" "pasa" produccion previa "$M/900_prueba.sql" "$M/901_segunda.sql"
dice "EQUAL" "^EQUAL +fn +public\.fn_a\(\)"
dice "veredicto SEGURO" "^VEREDICTO: SEGURO"
cierto "un solo docker (una transaccion de staging)" test "$(wc -l < "$TMP/docker.args")" -eq 1
cierto "los rollbacks van en orden inverso" bash -c "grep -o -E 'ROLLBACK_MARK_90[01]' '$TMP/sql/001.sql' | tr '\n' ' ' | grep -q 'ROLLBACK_MARK_901 ROLLBACK_MARK_900'"
cierto "y la transaccion termina en ROLLBACK" bash -c "tail -n1 '$TMP/sql/001.sql' | grep -qx 'ROLLBACK;'"
cierto "ni una sola escritura en produccion" bash -c "! grep -q '/database/migrations' '$TMP/curl.args'"
nodice "no imprime el token" "TOKEN_SECRETO_123"

nuevo_repo
fila fn 'public.fn_a()' m1 n1 'SELECT   1' > "$TMP/stg_rows.tsv"; fila fn 'public.fn_a()' mX n1 'SELECT 1' > "$TMP/prod_rows.tsv"
probar "previa con diferencia solo de espacios" "pasa" produccion previa "$M/900_prueba.sql"
dice "EQUAL-NORMALIZED" "^EQUAL-NORMALIZED +fn +public\.fn_a\(\)"
dice "sigue siendo SEGURO" "^VEREDICTO: SEGURO"

nuevo_repo
fila fn 'public.fn_a()' m1 n1 'cuerpo staging' > "$TMP/stg_rows.tsv"; fila fn 'public.fn_a()' mZ nZ 'cuerpo produccion' > "$TMP/prod_rows.tsv"
fila fn 'public.fn_b(integer)' m2 n2 'solo staging' >> "$TMP/stg_rows.tsv"
fila fn 'public.fn_extra()' m3 n3 'solo produccion' >> "$TMP/prod_rows.tsv"
probar "previa con diferencias" "RECHAZA" produccion previa "$M/900_prueba.sql" "$M/901_segunda.sql"
dice "DIFFERENT" "^DIFFERENT +fn +public\.fn_a\(\)"
dice "MISSING-IN-PROD" "^MISSING-IN-PROD +fn +public\.fn_b"
dice "EXTRA-IN-PROD" "^EXTRA-IN-PROD +fn +public\.fn_extra"
dice "veredicto REVISAR con el numero" "^VEREDICTO: REVISAR \(3 diferencias\)"
dice "ruta del diff" "diff: .*previa-diff.*\.txt"
dif=$(sed -n 's/^diff: //p' "$TMP/salida" | head -1)
cierto "el diff trae ambos cuerpos" bash -c "grep -q 'cuerpo staging' '$dif' && grep -q 'cuerpo produccion' '$dif'"

nuevo_repo
rm "$M/ROLLBACK-901-segunda.sql"
probar "previa sin el ROLLBACK de una migracion" "RECHAZA" produccion previa "$M/900_prueba.sql" "$M/901_segunda.sql"
dice "dice cual falta" "ROLLBACK-901"

echo
echo "=== produccion-migracion.sh aplicar ==="

nuevo_repo
FAKE_RECORDED='[{"name":"901_segunda"}]' probar "aplicar con un nombre ya registrado" "RECHAZA" produccion aplicar "$M/900_prueba.sql" "$M/901_segunda.sql"
dice "dice RECORDED" "RECORDED.*901_segunda"
cierto "y no envio NADA (ni la primera)" bash -c "! grep -q '/database/migrations' '$TMP/curl.args'"

nuevo_repo
echo '-- BOOM' >> "$M/900_prueba.sql"
probar "aplicar para en el primer error de la API" "RECHAZA" produccion aplicar "$M/900_prueba.sql" "$M/901_segunda.sql"
dice "muestra el mensaje de la API" "boom: syntax error"
dice "dice cual fichero" "900_prueba"
cierto "no mando la segunda" bash -c "[ \$(grep -c '/database/migrations' '$TMP/curl.args') -eq 1 ]"
cierto "ninguna peticion llevo la segunda" bash -c "! grep -l '901_segunda' \$(grep -l '\"name\"' '$TMP'/api/*.json)"
nodice "no imprime el token" "TOKEN_SECRETO_123"
cierto "el token nunca estuvo en argv" bash -c "! grep -q TOKEN_SECRETO_123 '$TMP/curl.args'"

nuevo_repo
probar "aplicar dos migraciones" "pasa" produccion aplicar "$M/900_prueba.sql" "$M/901_segunda.sql"
dice "OK nombre y version" "^OK 900_prueba 20261021000000"
dice "OK de la segunda" "^OK 901_segunda 20261021000000"
cierto "envio el fichero tal cual y con su nombre" bash -c "jq -e '.name==\"900_prueba\" and (.query|test(\"fn_a\"))' '$TMP/api/002.json' >/dev/null"
cierto "con el token en la cabecera (no en argv)" bash -c "test -s '$TMP/curl.auth' && ! grep -q TOKEN_SECRETO_123 '$TMP/curl.args'"
nodice "no imprime el token" "TOKEN_SECRETO_123"

echo
echo "=== produccion-migracion.sh verificar ==="

nuevo_repo
fila fn 'public.fn_a()' m1 n1 'a' > "$TMP/stg_rows.tsv"; fila fn 'public.fn_b(integer)' m2 n2 'b' >> "$TMP/stg_rows.tsv"
cp "$TMP/stg_rows.tsv" "$TMP/prod_rows.tsv"
probar "verificar con todo igual" "pasa" produccion verificar "$M/900_prueba.sql" "$M/901_segunda.sql"
dice "cuenta 2/2" "^VERIFICADO: 2/2 iguales"
dice "tabla con el dueno final" "public\.fn_b\(integer\) +901_segunda +EQUAL"

nuevo_repo
fila fn 'public.fn_a()' m1 n1 'a' > "$TMP/stg_rows.tsv"; fila fn 'public.fn_b(integer)' m2 n2 'b' >> "$TMP/stg_rows.tsv"
fila fn 'public.fn_a()' m1 n1 'a' > "$TMP/prod_rows.tsv"; fila fn 'public.fn_b(integer)' mMAL nMAL 'b2' >> "$TMP/prod_rows.tsv"
probar "verificar con un md5 distinto" "RECHAZA" produccion verificar "$M/900_prueba.sql" "$M/901_segunda.sql"
dice "lista el que difiere" "public\.fn_b\(integer\) +901_segunda +DIFFERENT"
dice "cuenta 1/2" "^NO VERIFICADO: 1/2 iguales"

nuevo_repo
fila fn 'public.fn_a()' m1 n1 'a' > "$TMP/stg_rows.tsv"
: > "$TMP/prod_rows.tsv"
probar "verificar con una funcion que falta en produccion" "RECHAZA" produccion verificar "$M/900_prueba.sql"
dice "la marca" "public\.fn_a\(\) +900_prueba +MISSING-IN-PROD"

echo
echo "=================================================="
if [[ "$fallos" -eq 0 ]]; then echo "  todo en pie"; else echo "  $fallos FALLOS"; fi
echo "=================================================="
exit "$fallos"
