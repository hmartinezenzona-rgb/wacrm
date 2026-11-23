#!/usr/bin/env bash
# Nightly Cerebro improvement: collect, review through Hermes, eval-gate and
# (optionally) apply a low-risk candidate. Runs from a systemd user timer at
# 00:15. Nothing is applied unless the classifier and the eval battery agree.
#
#   infra/ia/mejora_nocturna.sh [--dry] [--sin-aplicar]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SALIDA="$HOME/cerebro-fase1/mejora-nocturna"
EVALS="$HOME/cerebro-fase1/pruebas/evals"
PROMPT="$EVALS/contrato/prompt-sistema.txt"
FREELM="$HOME/.local/share/freellmapi-app"
DRY=0
APLICAR=1

for a in "$@"; do
  case "$a" in
    --dry) DRY=1 ;;
    --sin-aplicar) APLICAR=0 ;;
    *) echo "uso: $0 [--dry] [--sin-aplicar]" >&2; exit 2 ;;
  esac
done

paso() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fallo() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ $DRY == 1 ]]; then
  echo "plan: router -> colectar_dia -> evaluar.py --exportar-contrato -> mejora_nocturna.py"
  [[ $APLICAR == 1 ]] && echo "plan: si hay candidato bajo -> aplicar_candidato.py --aplicar"
  exit 0
fi

# 1. Router: Hermes needs the ORIGINAL FreeLLMAPI server on 3001.
if ! curl -sS -m 5 http://127.0.0.1:3001/api/ping >/dev/null 2>&1; then
  paso "router caido; levantando FreeLLMAPI desde $FREELM"
  ( cd "$FREELM" && nohup setsid npm start -w server > /tmp/freellmapi-server.log 2>&1 < /dev/null & )
  for _ in $(seq 1 15); do
    sleep 2
    curl -sS -m 5 http://127.0.0.1:3001/api/ping >/dev/null 2>&1 && break
  done
  curl -sS -m 5 http://127.0.0.1:3001/api/ping >/dev/null 2>&1 \
    || fallo "el router FreeLLMAPI no responde en 3001"
fi

# 2. Collect the last 24 h (read-only).
mkdir -p "$SALIDA/dias"; chmod 700 "$SALIDA" "$SALIDA/dias"
DIA="$SALIDA/dias/dia-$(date -u +%Y%m%dT%H%M%SZ).json"
paso "colectando el dia -> $DIA"
python3 "$ROOT/infra/ia/colectar_dia.py" --horas 24 --salida "$DIA" || fallo "el colector fallo"

# 3. Refresh the production prompt snapshot (read-only against n8n).
paso "refrescando el contrato del prompt"
( cd "$EVALS" && python3 evaluar.py --exportar-contrato ) || fallo "no se pudo refrescar el contrato"
[[ -s "$PROMPT" ]] || fallo "no existe $PROMPT"

# 4. Review through Hermes and classify the proposals.
MARCA="$(mktemp)"
paso "revision nocturna"
python3 "$ROOT/infra/ia/mejora_nocturna.py" --dia "$DIA" --prompt-actual "$PROMPT" \
  --salida-dir "$SALIDA" || fallo "la revision fallo"

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

rm -f "$MARCA"
paso "listo; informes en $SALIDA"
