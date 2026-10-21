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
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export TMP_REGISTRO="$TMP"

# ─── un repo de mentira con los scripts dentro ──────────────────────────────
nuevo_repo() {
    REPO="$TMP/repo"; rm -rf "$REPO" "$TMP/sql" "$TMP"/*.args "$TMPDIR"/*
    mkdir -p "$REPO/infra/db" "$REPO/supabase/migrations" "$REPO/supabase/staging/assertions"
    cp "$RAIZ_DB"/*.sh "$REPO/infra/db/" 2>/dev/null
    echo 'CRM_STAGING_DATABASE_URL=postgres://falso' > "$REPO/.env.staging"
    M="$REPO/supabase/migrations"; A="$REPO/supabase/staging/assertions"
    printf -- '-- MIGRATED_MARK\nCREATE FUNCTION fn_a() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;\n' > "$M/900_prueba.sql"
    printf -- '-- ROLLBACK_MARK\nDROP FUNCTION fn_a();\n' > "$M/ROLLBACK-900-prueba.sql"
    printf '\\set ON_ERROR_STOP on\n-- ALL_PASS_OK\nBEGIN;\nSELECT 1;\nROLLBACK;\n' > "$A/prueba.sql"
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
echo "=================================================="
if [[ "$fallos" -eq 0 ]]; then echo "  todo en pie"; else echo "  $fallos FALLOS"; fi
echo "=================================================="
exit "$fallos"
