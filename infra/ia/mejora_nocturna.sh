#!/usr/bin/env bash
# Nightly Cerebro improvement: collect, review through the CRM Hermes (the
# internal route that adds HERMES_API_KEY server-side), eval-gate and
# optionally apply a low-risk candidate.
#
#   infra/ia/mejora_nocturna.sh [--dry] [--sin-aplicar]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SALIDA="$HOME/cerebro-fase1/mejora-nocturna"
EVALS="$HOME/cerebro-fase1/pruebas/evals"
PROMPT="$EVALS/contrato/prompt-sistema.txt"
CRM_URL="${CRM_REVIEW_URL:-https://wacrm.onlinefreedom.site/api/internal/hermes/review}"
ENV_PROD="$HOME/.config/wacrm/prod-db.env"
DRY=0
APLICAR=1
SECRET_FILE=""
SQL_FILE=""
MARCA=""

for a in "$@"; do
  case "$a" in
    --dry) DRY=1 ;;
    --sin-aplicar) APLICAR=0 ;;
    *) echo "uso: $0 [--dry] [--sin-aplicar]" >&2; exit 2 ;;
  esac
done

trap 'rm -f "$SECRET_FILE" "$SQL_FILE" "$MARCA"' EXIT

paso() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fallo() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ $DRY == 1 ]]; then
  echo "plan: secreto -> colectar_dia -> evaluar.py --exportar-contrato -> ruta interna del CRM Hermes"
  [[ $APLICAR == 1 ]] && echo "plan: si hay candidato bajo -> aplicar_candidato.py --aplicar"
  echo "crm: $CRM_URL"
  exit 0
fi

# 1. Shared secret for the internal route, read-only from production.
[[ -r "$ENV_PROD" ]] || fallo "falta $ENV_PROD"
SECRET_FILE="$(mktemp)"; chmod 600 "$SECRET_FILE"
SQL_FILE="$(mktemp)"
printf "select valor from cerebro_config where clave = 'notify_secret';\n" > "$SQL_FILE"
docker run --rm -i --env-file "$ENV_PROD" postgres:17-alpine \
  sh -c 'psql -X -q -A -t "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 -f -' \
  < "$SQL_FILE" > "$SECRET_FILE" || fallo "no se pudo leer notify_secret"
[[ -s "$SECRET_FILE" ]] || fallo "notify_secret vacio"
paso "secreto de la ruta interna listo"

# 2. Collect the last 24 h (read-only).
mkdir -p "$SALIDA/dias"; chmod 700 "$SALIDA" "$SALIDA/dias"
DIA="$SALIDA/dias/dia-$(date -u +%Y%m%dT%H%M%SZ).json"
paso "colectando el dia -> $DIA"
python3 "$ROOT/infra/ia/colectar_dia.py" --horas 24 --salida "$DIA" || fallo "el colector fallo"

# 3. Refresh the production prompt snapshot (read-only against n8n).
paso "refrescando el contrato del prompt"
( cd "$EVALS" && python3 evaluar.py --exportar-contrato ) || fallo "no se pudo refrescar el contrato"
[[ -s "$PROMPT" ]] || fallo "no existe $PROMPT"

# 4. Review through the CRM Hermes and classify the proposals.
MARCA="$(mktemp)"
paso "revision nocturna via el Hermes del CRM"
python3 "$ROOT/infra/ia/mejora_nocturna.py" --dia "$DIA" --prompt-actual "$PROMPT" \
  --salida-dir "$SALIDA" --backend crm --crm-url "$CRM_URL" --secret-file "$SECRET_FILE" \
  || fallo "la revision fallo"

# 5. Apply only a candidate created by this run and classified low-risk.
CAND="$(ls -t "$SALIDA"/candidato-*.txt 2>/dev/null | head -1 || true)"
if [[ -n "$CAND" && "$CAND" -nt "$MARCA" ]]; then
  if [[ $APLICAR == 1 ]]; then
    paso "candidato bajo: compuerta de evals y aplicacion -> $CAND"
    python3 "$ROOT/infra/ia/aplicar_candidato.py" --candidato "$CAND" --riesgo bajo \
      --etiqueta "nocturna-$(date -u +%Y%m%d)" --aplicar \
      || fallo "la compuerta de evals rechazo el candidato"
  else
    paso "candidato bajo: solo compuerta de evals (sin aplicar)"
    python3 "$ROOT/infra/ia/aplicar_candidato.py" --candidato "$CAND" --riesgo bajo \
      --etiqueta "nocturna-$(date -u +%Y%m%d)" \
      || fallo "la compuerta de evals rechazo el candidato"
  fi
else
  paso "sin candidato de bajo riesgo; solo queda el informe"
fi

paso "listo; informes en $SALIDA"
