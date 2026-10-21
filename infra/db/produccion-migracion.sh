#!/usr/bin/env bash
# Migraciones en PRODUCCION por la Management API de Supabase, sin pegar SQL en la conversacion.
#
#   produccion-migracion.sh previa    <mig1.sql> [mig2.sql ...]   solo lectura: staging previo vs produccion
#   produccion-migracion.sh aplicar   <mig1.sql> [mig2.sql ...]   aplica en orden y registra cada una
#   produccion-migracion.sh verificar <mig1.sql> [mig2.sql ...]   md5 de cada funcion, produccion vs staging
#
# El token sale de ~/.config/wacrm/supabase-token.env (modo 600, SUPABASE_ACCESS_TOKEN=...). Nunca se
# imprime ni va en argv: curl lo lee de un fichero de configuracion que se genera en un descriptor.
# Salida corta (tablas y veredicto); el detalle va a ficheros bajo ${TMPDIR:-/tmp}.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-migracion.sh"

AQUI="$(dirname "${BASH_SOURCE[0]}")"
REF="hqztotshnlzaiziwjyzh"
API="https://api.supabase.com/v1/projects/$REF"
LOG_DIR="${TMPDIR:-/tmp}"
TOKEN_FILE="$HOME/.config/wacrm/supabase-token.env"
SELLO="$(date +%Y%m%d%H%M%S)"
LOG="$LOG_DIR/produccion-migracion-$SELLO.log"
PY() { python3 -I "$AQUI/migracion_sql.py" "$@"; }

uso() { sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

TRABAJO=$(mktemp -d "$LOG_DIR/prod-mig-XXXXXX"); trap 'rm -rf "$TRABAJO"' EXIT

# SQL de lectura contra produccion; imprime la respuesta JSON.
consulta_prod() {
    jq -n --arg q "$1" '{query: $q}' > "$TRABAJO/q.json"
    api_post /database/query "$TRABAJO/q.json"
    api_ok || die "produccion rechazo la consulta (HTTP $API_CODE): $(api_mensaje)"
    cat "$API_RESP"
}

# ─── utilidades ─────────────────────────────────────────────────────────────
nombre_de() {   # 257_cup_source_card.sql -> 257_cup_source_card
    local n; n=$(basename "$1" .sql)
    [[ "$n" =~ ^[A-Za-z0-9_.-]+$ ]] || die "nombre de migracion no admitido: $n"
    echo "$n"
}

resolver_migraciones() {   # llena RUTAS y NOMBRES
    RUTAS=(); NOMBRES=()
    local f
    for f in "$@"; do RUTAS+=("$(fichero "$f")"); NOMBRES+=("$(nombre_de "$f")"); done
}

rollback_de() {   # ruta migracion -> ruta ROLLBACK-<numero>-*.sql en la misma carpeta
    local d n num r; d=$(dirname "$1"); n=$(basename "$1")
    num="${n%%_*}"
    local c=("$d"/ROLLBACK-"$num"-*.sql)
    [[ -f "${c[0]}" ]] || die "falta el ROLLBACK de $n (busque ROLLBACK-$num-*.sql en $d)"
    [[ ${#c[@]} -eq 1 ]] || die "hay varios ROLLBACK-$num-*.sql en $d"
    echo "${c[0]}"
}

comprobar_registradas() {   # termina con RECORDED si alguna ya esta en produccion
    local lista="" n
    for n in "${NOMBRES[@]}"; do lista+="'$n',"; done
    local filas; filas=$(consulta_prod "select name from supabase_migrations.schema_migrations where name in (${lista%,})") || exit 1
    local reg; reg=$(jq -r '.[].name' <<<"$filas")
    if [[ -n "$reg" ]]; then
        while read -r n; do echo "RECORDED $n   (ya esta en supabase_migrations.schema_migrations de produccion)"; done <<<"$reg"
        echo "Se niega: esa migracion ya se aplico en produccion."
        exit 2
    fi
}

# Consulta INVENTARIO: funciones por nombre y, de las tablas, columnas/constraints/triggers/indices.
# Una fila por objeto: kind, key, md5, md5 normalizado, cuerpo base64 (tabuladas, en la columna r).
sql_inventario() {   # $1 funciones "a,b" · $2 tablas "a,b" (calificadas)
    local fns tbls
    fns=$(sed "s/[^,][^,]*/'&'/g" <<<"$1"); tbls=$(sed "s/[^,][^,]*/'&'/g" <<<"$2")
    cat <<SQL
-- INVENTARIO
SELECT concat_ws(E'\t', kind, key, md5(def), md5(regexp_replace(def, '\s+', ' ', 'g')),
                 replace(encode(convert_to(def, 'UTF8'), 'base64'), E'\n', '')) AS r
FROM (
  SELECT 'fn'::text AS kind, format('%s.%s(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS key,
         pg_get_functiondef(p.oid) AS def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE p.prokind IN ('f', 'p') AND n.nspname || '.' || p.proname = ANY (ARRAY[${fns}]::text[])
  UNION ALL
  SELECT 'col', format('%s.%s.%s', n.nspname, c.relname, a.attname),
         format_type(a.atttypid, a.atttypmod) || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
         || coalesce(' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid), '')
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r', 'p')
     AND n.nspname || '.' || c.relname = ANY (ARRAY[${tbls}]::text[])
  UNION ALL
  SELECT 'con', format('%s.%s:%s', n.nspname, c.relname, k.conname), pg_get_constraintdef(k.oid)
    FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname || '.' || c.relname = ANY (ARRAY[${tbls}]::text[])
  UNION ALL
  SELECT 'trg', format('%s.%s~%s', n.nspname, c.relname, t.tgname), pg_get_triggerdef(t.oid)
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE NOT t.tgisinternal AND n.nspname || '.' || c.relname = ANY (ARRAY[${tbls}]::text[])
  UNION ALL
  SELECT 'idx', format('%s.%s#%s', schemaname, tablename, indexname), indexdef
    FROM pg_indexes WHERE schemaname || '.' || tablename = ANY (ARRAY[${tbls}]::text[])
) q ORDER BY q.key;
SQL
}

# Objetos que tocan los ficheros: llena FNS y TBLS (listas separadas por comas, sin repetidos).
objetos_de() {
    PY objetos "${RUTAS[@]}" > "$TRABAJO/objetos.tsv" || die "no pude leer las migraciones"
    FNS=$(awk -F'\t' '$1=="fn"{print $2}' "$TRABAJO/objetos.tsv" | sort -u | paste -sd,)
    TBLS=$(awk -F'\t' '$1=="tbl"{print $2}' "$TRABAJO/objetos.tsv" | sort -u | paste -sd,)
}

inventario_prod() {   # $1 funciones · $2 tablas · $3 salida
    consulta_prod "$(sql_inventario "$1" "$2")" | jq -r '.[].r' > "$3"
}

# ─── previa ─────────────────────────────────────────────────────────────────
cmd_previa() {
    [[ $# -ge 1 ]] || uso
    resolver_migraciones "$@"
    local i rollbacks=()
    for ((i=${#RUTAS[@]}-1; i>=0; i--)); do rollbacks+=("$(rollback_de "${RUTAS[i]}")") || exit 1; done
    cargar_token
    comprobar_registradas
    objetos_de
    [[ -n "$FNS$TBLS" ]] || die "no encontre ninguna funcion ni tabla en las migraciones"

    # Estado de staging ANTES del paquete: los ROLLBACK en orden inverso, en UNA transaccion que se revierte.
    {   echo 'BEGIN;'
        for r in "${rollbacks[@]}"; do cat "$r"; echo; done
        sql_inventario "$FNS" "$TBLS"
        echo 'ROLLBACK;'
    } | psql_staging > "$TRABAJO/staging.tsv" 2> "$TRABAJO/staging.err"
    if [[ $? -ne 0 ]]; then
        echo "staging rechazo los ROLLBACK: $(grep -m1 -oE 'ERROR: .*' "$TRABAJO/staging.err")"
        cp "$TRABAJO/staging.err" "$LOG_DIR/previa-staging-$SELLO.err"; echo "log: $LOG_DIR/previa-staging-$SELLO.err"
        exit 1
    fi
    inventario_prod "$FNS" "$TBLS" "$TRABAJO/prod.tsv"

    tr ',' '\n' <<<"$FNS" | sed '/^$/d' > "$TRABAJO/nombres.txt"
    PY previa "$TRABAJO/staging.tsv" "$TRABAJO/prod.tsv" "$TRABAJO/nombres.txt" "$LOG_DIR/previa-diff-$SELLO.txt"
}

# ─── aplicar ────────────────────────────────────────────────────────────────
cmd_aplicar() {
    [[ $# -ge 1 ]] || uso
    resolver_migraciones "$@"
    cargar_token
    comprobar_registradas
    local i n f
    for ((i=0; i<${#RUTAS[@]}; i++)); do
        n="${NOMBRES[i]}"; f="${RUTAS[i]}"
        jq -Rs --arg n "$n" '{query: ., name: $n}' "$f" > "$TRABAJO/mig.json"
        api_post /database/migrations "$TRABAJO/mig.json"
        if ! api_ok; then
            echo "FAIL $n (HTTP $API_CODE): $(api_mensaje)"
            echo "Se detiene aqui; sin aplicar: ${NOMBRES[*]:i+1}"
            echo "log: $LOG"
            exit 1
        fi
        local v
        v=$(consulta_prod "select version from supabase_migrations.schema_migrations where name = '$n' order by version desc limit 1" | jq -r '.[0].version // empty')
        if [[ -z "$v" ]]; then
            echo "FAIL $n: la API acepto la migracion pero no aparece en schema_migrations; revisar a mano"
            echo "log: $LOG"
            exit 1
        fi
        echo "OK $n $v"
    done
}

# ─── verificar ──────────────────────────────────────────────────────────────
cmd_verificar() {
    [[ $# -ge 1 ]] || uso
    resolver_migraciones "$@"
    cargar_token
    objetos_de
    # Duena final de cada funcion = la ultima migracion que la crea; si la ultima accion es un DROP, no cuenta.
    awk -F'\t' '$1=="fn" { if ($3=="create") dueno[$2]=$4; if ($3=="drop") delete dueno[$2] }
                END { for (n in dueno) print n "\t" dueno[n] }' "$TRABAJO/objetos.tsv" | sort > "$TRABAJO/owners.tsv"
    [[ -s "$TRABAJO/owners.tsv" ]] || { echo "VERIFICADO: 0/0 iguales (las migraciones no definen funciones)"; return 0; }
    local fns; fns=$(cut -f1 "$TRABAJO/owners.tsv" | paste -sd,)
    sql_inventario "$fns" "" | psql_staging > "$TRABAJO/staging.tsv" 2> "$TRABAJO/staging.err" \
        || die "staging fallo: $(grep -m1 -oE 'ERROR: .*' "$TRABAJO/staging.err")"
    inventario_prod "$fns" "" "$TRABAJO/prod.tsv"
    PY verificar "$TRABAJO/staging.tsv" "$TRABAJO/prod.tsv" "$TRABAJO/owners.tsv"
}

case "${1:-}" in
    previa)    shift; cmd_previa "$@" ;;
    aplicar)   shift; cmd_aplicar "$@" ;;
    verificar) shift; cmd_verificar "$@" ;;
    *) uso ;;
esac
