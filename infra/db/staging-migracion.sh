#!/usr/bin/env bash
# Ciclo de una migracion en STAGING: ensayo, aplicacion, asercion, prueba de rollback y
# aserciones relacionadas. Todo el SQL se manda desde ficheros; nada pasa por la conversacion.
#
#   staging-migracion.sh aplicar <migracion.sql> <asercion.sql> <ROLLBACK.sql> [func1,func2,...]
#   staging-migracion.sh relacionadas <migracion.sql> <patron> [asercion-a-saltar] [--ya-aplicada <ROLLBACK.sql>]
#
# Salida corta (una linea por paso); el detalle completo va a un log cuya ruta se imprime si algo falla.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-migracion.sh"

LOG_DIR="${TMPDIR:-/tmp}"

uso() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# ─── aplicar ────────────────────────────────────────────────────────────────
md5_funciones() {   # $1 lista "a,b,c" -> filas nombre|md5|acl (vacio sin lista)
    [[ -n "$1" ]] || return 0
    local lista="'${1//,/\',\'}'"
    echo "SELECT proname || '|' || md5(pg_get_functiondef(oid)) || '|' || coalesce(proacl::text, '') FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ($lista) AND prokind = 'f' ORDER BY 1;" | psql_staging
}

cmd_aplicar() {
    [[ $# -ge 3 ]] || uso
    local mig asr rbk fns="${4:-}"
    mig=$(fichero "$1") || exit 1; asr=$(fichero "$2") || exit 1; rbk=$(fichero "$3") || exit 1
    [[ -f "$RAIZ/.env.staging" ]] || die "falta $RAIZ/.env.staging"
    local log="$LOG_DIR/staging-migracion-$(basename "$mig" .sql)-$(date +%Y%m%d%H%M%S).log"
    : > "$log"
    local lista_md5=""

    fallo() {   # $1 paso · $2 salida del paso
        local e; e=$(grep -m1 -oE 'ERROR: .*' <<<"$2")
        printf '%-11s FAIL  %s\n' "$1" "${e:-sin linea ERROR}"
        echo "log: $log"
        exit 1
    }
    registrar() { { echo "### $1"; echo "$2"; echo; } >> "$log"; }

    # 1. ensayo: migracion + asercion en una transaccion que se revierte. La asercion termina
    #    con un RAISE 'ALL PASS ...', asi que la ultima linea ERROR tiene que ser esa.
    local salida
    salida=$({ echo 'BEGIN;'; cat "$mig"; quitar_tx "$asr"; echo 'ROLLBACK;'; } | psql_staging 2>&1); registrar dry-run "$salida"
    grep -E 'ERROR' <<<"$salida" | tail -1 | grep -q 'ALL PASS' || fallo dry-run "$salida"
    printf '%-11s OK\n' dry-run
    [[ "${DRY_ONLY:-0}" == 1 ]] && exit 0

    # md5 previo (para comparar con el de la prueba de rollback)
    local previo; previo=$(md5_funciones "$fns" 2>&1); registrar previo "$previo"

    # 2. aplicar
    salida=$({ echo 'BEGIN;'; cat "$mig"; echo 'COMMIT;'; } | psql_staging 2>&1); local rc=$?; registrar apply "$salida"
    if [[ $rc -ne 0 ]] || grep -q 'ERROR' <<<"$salida"; then fallo apply "$salida"; fi
    printf '%-11s OK\n' apply

    # 3. la asercion otra vez, ya con la migracion aplicada
    salida=$({ echo 'BEGIN;'; quitar_tx "$asr"; echo 'ROLLBACK;'; } | psql_staging 2>&1); registrar assertion "$salida"
    grep -E 'ERROR' <<<"$salida" | tail -1 | grep -q 'ALL PASS' || fallo assertion "$salida"
    printf '%-11s OK\n' assertion

    local aplicado; aplicado=$(md5_funciones "$fns" 2>&1); registrar funciones "$aplicado"

    # 4. el rollback, dentro de una transaccion que se revierte: tiene que dejar el md5 previo
    salida=$({ echo 'BEGIN;'; cat "$rbk"; if [[ -n "$fns" ]]; then
        echo "SELECT proname || '|' || md5(pg_get_functiondef(oid)) || '|' || coalesce(proacl::text, '') FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('${fns//,/\',\'}') AND prokind = 'f' ORDER BY 1;"
      fi; echo 'ROLLBACK;'; } | psql_staging 2>&1); rc=$?; registrar rollback "$salida"
    if [[ $rc -ne 0 ]] || grep -q 'ERROR' <<<"$salida"; then fallo rollback "$salida"; fi
    if [[ -n "$fns" ]]; then
        if [[ "$salida" != "$previo" ]]; then
            printf '%-11s FAIL  el md5 tras el rollback no es el previo a la migracion\n' rollback
            echo "log: $log"; exit 1
        fi
        printf '%-11s OK  (md5 igual al previo)\n' rollback
    else
        printf '%-11s OK  (sin funciones que comparar)\n' rollback
    fi

    if [[ -n "$fns" ]]; then
        echo "-- funciones tras aplicar (nombre md5 acl)"
        while IFS='|' read -r n m a; do [[ -n "$n" ]] && printf '%-34s %s  %s\n' "$n" "${m:0:12}" "$a"; done <<<"$aplicado"
    fi
}

# ─── relacionadas ───────────────────────────────────────────────────────────
# Cada asercion que coincide con el patron corre dos veces, en transacciones que se revierten:
# sin la migracion (base) y con ella. SAME si el primer error es el mismo. Si la migracion ya esta
# aplicada en staging hay que decirlo con --ya-aplicada <ROLLBACK.sql>: ambas corridas arrancan
# entonces con ese rollback, de modo que la base es de verdad el estado previo.
cmd_relacionadas() {
    local ya="" skip="__none__" pos=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ya-aplicada) [[ $# -ge 2 ]] || die "--ya-aplicada necesita el fichero ROLLBACK"; ya=$(fichero "$2") || exit 1; shift 2 ;;
            *) pos+=("$1"); shift ;;
        esac
    done
    [[ ${#pos[@]} -ge 2 ]] || uso
    local mig pat="${pos[1]}"; mig=$(fichero "${pos[0]}") || exit 1; skip="${pos[2]:-__none__}"
    [[ -f "$RAIZ/.env.staging" ]] || die "falta $RAIZ/.env.staging"
    local logs; logs=$(mktemp -d "$LOG_DIR/relacionadas-XXXXXX")
    local same=0 diff=0 total=0 f n b c s
    local previo=""; [[ -n "$ya" ]] && previo=$(cat "$ya")

    # Una a una: dos corridas en paralelo se bloquearon entre si una vez.
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        n=$(basename "$f" .sql)
        { echo 'BEGIN;'; [[ -n "$ya" ]] && echo "$previo"; quitar_tx "$f"; echo 'ROLLBACK;'; } | psql_staging > "$logs/$n.base.log" 2>&1
        { echo 'BEGIN;'; [[ -n "$ya" ]] && echo "$previo"; cat "$mig"; quitar_tx "$f"; echo 'ROLLBACK;'; } | psql_staging > "$logs/$n.mig.log" 2>&1
        b=$(primer_error "$logs/$n.base.log"); c=$(primer_error "$logs/$n.mig.log")
        if [[ "$b" == "$c" ]]; then s=SAME; same=$((same+1)); else s=DIFF; diff=$((diff+1)); fi
        total=$((total+1))
        echo "$s | $n | base: ${b:-no error} | mig: ${c:-no error}"
    done < <(grep -l -E -- "$pat" "$RAIZ"/supabase/staging/assertions/*.sql 2>/dev/null | grep -v -- "$skip")

    echo "TOTAL $total | SAME $same | DIFF $diff   (logs: $logs)"
    [[ $diff -eq 0 ]]
}

case "${1:-}" in
    aplicar)       shift; cmd_aplicar "$@" ;;
    relacionadas)  shift; cmd_relacionadas "$@" ;;
    *) uso ;;
esac
