#!/usr/bin/env bash
# correccion-produccion.sh, probado intentando hacerlo mal.
#
# Nada toca produccion ni la red: `curl` es postizo y el token es falso (en un HOME temporal).
# Se comprueba que el script se NIEGA donde debe y que, en el camino bueno, manda a la API
# exactamente el fichero que se le pasa, sin imprimir ni poner en argv el token.
set -uo pipefail
RAIZ_DB="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$RAIZ_DB/correccion-produccion.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$TMP"' EXIT
fallos=0
TOKEN_SECRETO="TOKEN_SECRETO_987"

# ─── postizo de curl ────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'FIN'
#!/usr/bin/env bash
# Registra argv, el cuerpo y la cabecera de autorizacion; contesta segun FAKE_CURL_CODE.
R="$TMP_REGISTRO"
printf '%s\n' "$*" >> "$R/curl.args"
out=""; body=""; prev=""
for a in "$@"; do
    case "$prev" in -o) out="$a" ;; --data-binary) body="${a#@}" ;; -K) cfg="$a" ;; esac
    prev="$a"
done
cp "$body" "$R/body.json"
[[ -n "${cfg:-}" ]] && grep -q 'Authorization: Bearer ' "$cfg" && echo auth >> "$R/curl.auth"
if [[ -n "${FAKE_CURL_CODE:-}" ]]; then
    printf '%s' '{"message":"syntax error at or near \"BOOM\""}' > "$out"
    printf '%s' "$FAKE_CURL_CODE"; exit 0
fi
printf '%s' '[{"filas":1}]' > "$out"
printf '%s' 201
FIN
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# ─── un caso = un directorio nuevo (HOME, registro y ficheros propios) ──────
nuevo_entorno() {
    CASO=$(mktemp -d "$TMP/caso.XXXX")
    export TMP_REGISTRO="$CASO/registro"; mkdir -p "$TMP_REGISTRO" "$CASO/casos" "$CASO/home/.config/wacrm"
    echo "SUPABASE_ACCESS_TOKEN=$TOKEN_SECRETO" > "$CASO/home/.config/wacrm/supabase-token.env"
    chmod 600 "$CASO/home/.config/wacrm/supabase-token.env"
    export HOME="$CASO/home"
    unset FAKE_CURL_CODE
    BUENO="$CASO/casos/correccion.sql"
    printf -- "-- Corrige la operacion X (dueno: 2026-10-21)\nDO \$\$\nBEGIN\n  UPDATE remittance_operations SET quoted_destination_amount = 100 WHERE id = '00000000-0000-0000-0000-000000000001';\nEND\n\$\$;\n" > "$BUENO"
}

llamadas() { [[ -f "$TMP_REGISTRO/curl.args" ]] && wc -l < "$TMP_REGISTRO/curl.args" || echo 0; }

correr() {   # resto: argumentos del script. Salida en $CASO/salida, codigo en $codigo
    bash "$SCRIPT" "$@" > "$CASO/salida" 2>&1
    codigo=$?
}

probar() {   # $1 nombre · $2 pasa|RECHAZA · resto: argumentos
    local nombre="$1" esperado="$2"; shift 2
    correr "$@"
    local real="RECHAZA"; [[ $codigo -eq 0 ]] && real="pasa"
    if [[ "$real" == "$esperado" ]]; then echo "  ok      $nombre  ($real)"
    else echo "  FALLO   $nombre  (esperaba $esperado, dio $real)"; sed 's/^/            /' "$CASO/salida" | tail -6; fallos=$((fallos+1)); fi
}
dice() {   # $1 nombre · $2 patron que debe estar en la salida
    if grep -qE -- "$2" "$CASO/salida"; then echo "  ok      $1"
    else echo "  FALLO   $1 (no aparece /$2/)"; sed 's/^/            /' "$CASO/salida" | tail -6; fallos=$((fallos+1)); fi
}
cierto() {   # $1 nombre · resto: comando que debe salir bien
    local n="$1"; shift
    if "$@"; then echo "  ok      $n"; else echo "  FALLO   $n"; fallos=$((fallos+1)); fi
}
nodice() {   # $1 nombre · $2 texto que NO debe estar en la salida
    if grep -qF -- "$2" "$CASO/salida"; then echo "  FALLO   $1 (aparece $2)"; fallos=$((fallos+1)); else echo "  ok      $1"; fi
}

echo "=== correccion-produccion.sh: negativas ==="

nuevo_entorno
probar "sin --confirmar se niega" "RECHAZA" "$BUENO"
dice "dice que falta --confirmar" "--confirmar"
cierto "y no llama a la API" test "$(llamadas)" -eq 0

nuevo_entorno
chmod 644 "$HOME/.config/wacrm/supabase-token.env"
probar "token 0644 se niega" "RECHAZA" "$BUENO" --confirmar
dice "pide modo 600" "600"
nodice "no imprime el token" "$TOKEN_SECRETO"
cierto "y no llama a la API" test "$(llamadas)" -eq 0

nuevo_entorno
unlink "$HOME/.config/wacrm/supabase-token.env"
probar "sin fichero de token se niega" "RECHAZA" "$BUENO" --confirmar
dice "dice donde debe estar el token" "supabase-token\.env"

nuevo_entorno
printf 'DROP TABLE remittance_operations;\n' > "$CASO/casos/drop.sql"
probar "DROP TABLE se niega" "RECHAZA" "$CASO/casos/drop.sql" --confirmar
dice "lo dice" "DROP TABLE"
cierto "no llama a la API" test "$(llamadas)" -eq 0

nuevo_entorno
printf 'truncate remittance_calculator_entries;\n' > "$CASO/casos/trunc.sql"
probar "TRUNCATE (en minusculas) se niega" "RECHAZA" "$CASO/casos/trunc.sql" --confirmar

nuevo_entorno
printf 'DROP SCHEMA public CASCADE;\n' > "$CASO/casos/schema.sql"
probar "DROP SCHEMA se niega" "RECHAZA" "$CASO/casos/schema.sql" --confirmar

nuevo_entorno
printf 'ALTER TABLE remittance_operations DROP COLUMN notes;\n' > "$CASO/casos/col.sql"
probar "ALTER TABLE ... DROP COLUMN se niega" "RECHAZA" "$CASO/casos/col.sql" --confirmar

nuevo_entorno
printf 'ALTER TABLE remittance_operations\n  DROP\n  COLUMN notes;\n' > "$CASO/casos/col2.sql"
probar "DROP COLUMN partido en varias lineas se niega" "RECHAZA" "$CASO/casos/col2.sql" --confirmar

nuevo_entorno
printf '  \n\n' > "$CASO/casos/vacio.sql"; : > "$CASO/casos/cero.sql"
probar "fichero vacio se niega" "RECHAZA" "$CASO/casos/vacio.sql" --confirmar
probar "fichero de cero bytes se niega" "RECHAZA" "$CASO/casos/cero.sql" --confirmar
cierto "y no llama a la API" test "$(llamadas)" -eq 0

nuevo_entorno
probar "fichero inexistente se niega" "RECHAZA" "$CASO/casos/no-existe.sql" --confirmar

nuevo_entorno
probar "sin argumentos se niega" "RECHAZA"

nuevo_entorno
printf -- "-- este comentario dice DROP TABLE\nSELECT 1;\n" > "$CASO/casos/comentario.sql"
probar "un DROP TABLE dentro de un comentario NO cuenta" "pasa" "$CASO/casos/comentario.sql" --confirmar

echo
echo "=== correccion-produccion.sh: camino bueno ==="

nuevo_entorno
probar "con --confirmar y todo bien pasa" "pasa" "$BUENO" --confirmar
cierto "llamo a la API una vez" test "$(llamadas)" -eq 1
cierto "la URL es la de la consulta del proyecto de produccion" grep -q 'hqztotshnlzaiziwjyzh/database/query' "$TMP_REGISTRO/curl.args"
cierto "manda el fichero tal cual en .query" bash -c "jq -e --rawfile f '$BUENO' '.query == \$f' '$TMP_REGISTRO/body.json' >/dev/null"
cierto "el token va en una cabecera (fichero -K), no en argv" bash -c "test -s '$TMP_REGISTRO/curl.auth' && ! grep -qF '$TOKEN_SECRETO' '$TMP_REGISTRO/curl.args'"
nodice "el token no se imprime" "$TOKEN_SECRETO"
dice "imprime el resultado compacto" '^\[\{"filas":1\}\]$'

nuevo_entorno
FAKE_CURL_CODE=400 probar "error de la API: falla" "RECHAZA" "$BUENO" --confirmar
dice "muestra el mensaje de la API" "BOOM"
nodice "el error tampoco imprime el token" "$TOKEN_SECRETO"

echo
echo "=================================================="
if [[ "$fallos" -eq 0 ]]; then echo "  todo en pie"; else echo "  $fallos FALLOS"; fi
echo "=================================================="
exit "$fallos"
