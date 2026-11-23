#!/usr/bin/env python3
"""Collect the last N hours of real Cerebro traffic for the nightly review.

Read-only: the SQL runs inside BEGIN READ ONLY ... ROLLBACK against the
production database through docker, the same way informe_diario.py does.
The result contains customer text, so it is written to a 0600 file under
~/cerebro-fase1/mejora-nocturna/dias/ and never printed by default.

    python3 infra/ia/colectar_dia.py --horas 24
    python3 infra/ia/colectar_dia.py --salida /tmp/dia.json --stdout
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ENV_PROD = Path.home() / ".config" / "wacrm" / "prod-db.env"
VAR_PROD = "PROD_DATABASE_URL"
DEST = Path.home() / "cerebro-fase1" / "mejora-nocturna" / "dias"

SQL = r"""
BEGIN READ ONLY;
WITH rango AS (
  SELECT now() - make_interval(hours => {horas}) AS ini, now() AS fin
),
msgs AS (
  SELECT m.conversation_id, m.sender_type, m.content_type, m.created_at,
         left(COALESCE(NULLIF(m.content_text, ''),
                       CASE WHEN m.content_type <> 'text' THEN '[media]' ELSE '' END), 600) AS texto,
         row_number() OVER (PARTITION BY m.conversation_id ORDER BY m.created_at DESC) AS rn
    FROM messages m, rango r
   WHERE m.created_at >= r.ini AND m.created_at < r.fin
),
ultimos AS (SELECT * FROM msgs WHERE rn <= {max_msg}),
conv AS (
  SELECT u.conversation_id AS id,
         COALESCE(NULLIF(c.name, ''), c.phone) AS contacto,
         v.ai_autoreply_disabled AS bot_pausado,
         v.ai_handoff_reason AS pausa_razon,
         (v.assigned_agent_id IS NOT NULL) AS asignada,
         max(u.created_at) AS ultimo,
         jsonb_agg(jsonb_build_object(
           'remite', u.sender_type, 'tipo', u.content_type,
           'hora', to_char(u.created_at AT TIME ZONE 'UTC', 'HH24:MI'),
           'texto', u.texto) ORDER BY u.created_at) AS mensajes
    FROM ultimos u
    JOIN conversations v ON v.id = u.conversation_id
    JOIN contacts c ON c.id = v.contact_id
   GROUP BY 1, 2, 3, 4, 5
   ORDER BY ultimo DESC
   LIMIT {max_conv}
),
ops AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'op', left(o.id::text, 8), 'servicio', o.service_type, 'estado', o.status,
           'origen_gyd', o.quoted_source_amount)), '[]'::jsonb) AS lista
    FROM remittance_operations o, rango r
   WHERE (o.created_at >= r.ini AND o.created_at < r.fin)
      OR (o.updated_at >= r.ini AND o.updated_at < r.fin)
),
tools AS (
  SELECT COALESCE(jsonb_object_agg(tool_name, n), '{}'::jsonb) AS lista
    FROM (SELECT l.tool_name, count(*) AS n
            FROM tool_execution_log l, rango r
           WHERE l.created_at >= r.ini AND l.created_at < r.fin
           GROUP BY 1) t
),
sin_respuesta AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'conv', left(s.conversation_id::text, 8), 'contacto', s.contacto,
           'hora', to_char(s.created_at AT TIME ZONE 'UTC', 'HH24:MI'),
           'texto', left(COALESCE(s.texto, '[media]'), 200))), '[]'::jsonb) AS lista
    FROM (
      SELECT m.conversation_id, m.sender_type, m.content_type, m.created_at, m.texto,
             COALESCE(NULLIF(c.name, ''), c.phone) AS contacto,
             row_number() OVER (PARTITION BY m.conversation_id ORDER BY m.created_at DESC) AS rn
        FROM msgs m
        JOIN conversations v ON v.id = m.conversation_id
        JOIN contacts c ON c.id = v.contact_id
    ) s
   WHERE s.rn = 1 AND s.sender_type = 'customer'
     AND NOT (s.content_type = 'text' AND btrim(lower(COALESCE(s.texto, '')), E' \t\n.,!¡¿?:;-')
              ~ '^(|ok|oka|okay|okey|oki|vale|listo|dale|gra[cs]ias?|muchas gra[cs]ias?|perfecto|perfect|bien|bueno|entendido|entiendo|de acuerdo|thank you|thanks|thank u|ty|got it|understood|alright|sure|yes|yep|yeah|si|sí)$')
)
SELECT jsonb_build_object(
  'desde', to_char((SELECT ini FROM rango) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'hasta', to_char((SELECT fin FROM rango) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'conversaciones', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT * FROM conv) x), '[]'::jsonb),
  'operaciones', (SELECT lista FROM ops),
  'herramientas', (SELECT lista FROM tools),
  'sin_respuesta', (SELECT lista FROM sin_respuesta)
);
ROLLBACK;
"""


def error(msg: str) -> "NoReturn":  # noqa: F821
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def leer_url(env_file: Path) -> str:
    if not env_file.is_file():
        error(f"falta {env_file} con {VAR_PROD}=postgresql://...")
    for linea in env_file.read_text(encoding="utf-8").splitlines():
        if linea.startswith(VAR_PROD + "="):
            valor = linea.split("=", 1)[1].strip().strip("\"'")
            if valor:
                return valor
    error(f"{env_file} no trae {VAR_PROD}")


def consultar(url: str, sql: str) -> str:
    # The URL goes in through the environment, never on the command line.
    cmd = [
        "docker", "run", "--rm", "--network", "host", "-i",
        "-e", "PGCONNECT_TIMEOUT=10", "--env-file", str(ENV_PROD_FILE),
        "postgres:17-alpine",
        "sh", "-c", f'psql -X -q -A -t "${VAR_PROD}" -v ON_ERROR_STOP=1 -f -',
    ]
    entorno = dict(os.environ)
    entorno[VAR_PROD] = url
    try:
        r = subprocess.run(cmd, input=sql, capture_output=True, text=True,
                           env=entorno, timeout=180)
    except subprocess.TimeoutExpired:
        error("psql excedio 180 s")
    if r.returncode != 0:
        lineas = [l for l in (r.stderr or "").strip().splitlines() if l]
        error(lineas[-1] if lineas else f"psql codigo {r.returncode}")
    return r.stdout.strip()


def main() -> int:
    p = argparse.ArgumentParser(description="Collect last-N-hours Cerebro traffic (read-only)")
    p.add_argument("--horas", type=int, default=24)
    p.add_argument("--salida", type=Path, default=None)
    p.add_argument("--env-file", type=Path, default=ENV_PROD)
    p.add_argument("--max-conversaciones", type=int, default=80)
    p.add_argument("--max-mensajes", type=int, default=60)
    p.add_argument("--stdout", action="store_true", help="print the JSON (debug; contains customer text)")
    args = p.parse_args()

    if args.horas < 1 or args.max_conversaciones < 1 or args.max_mensajes < 1:
        error("--horas, --max-conversaciones y --max-mensajes deben ser >= 1")

    global ENV_PROD_FILE
    ENV_PROD_FILE = args.env_file
    url = leer_url(args.env_file)

    sql = (SQL.replace("{horas}", str(args.horas))
              .replace("{max_conv}", str(args.max_conversaciones))
              .replace("{max_msg}", str(args.max_mensajes)))
    salida = consultar(url, sql)
    try:
        data = json.loads(salida)
    except json.JSONDecodeError:
        error("el resultado de psql no es JSON")

    dest = args.salida or (DEST / f"dia-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}.json")
    dest.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(dest.parent, 0o700)
    dest.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.chmod(dest, 0o600)

    if args.stdout:
        print(json.dumps(data, ensure_ascii=False))
    print(f"ok {dest} conversaciones={len(data.get('conversaciones', []))} "
          f"sin_respuesta={len(data.get('sin_respuesta', []))} "
          f"desde={data.get('desde')} hasta={data.get('hasta')}")
    return 0


ENV_PROD_FILE = ENV_PROD


if __name__ == "__main__":
    sys.exit(main())
