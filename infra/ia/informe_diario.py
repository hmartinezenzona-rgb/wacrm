#!/usr/bin/env python3
"""Informe diario de conversaciones con Hermes -> WhatsApp del admin.

Flujo (v1, 2026-10-24):
  1. Lee la base de PRODUCCION en solo-lectura (PROD_DATABASE_URL, via docker; nunca imprime la URL).
  2. Arma el dataset del dia de negocio (09:00-17:00 hora de Guyana).
  3. Le pide a Hermes (one-shot, mismo CLI que delegar_hermes.py) el informe con la estructura acordada.
  4. Lo entrega por la puerta interna del panel (/api/internal/hermes/report), que lo encola en el
     outbox del admin (maneja la ventana de 24 h y el fallback de plantilla). Hermes no habla con WhatsApp.

Uso:
    python3 infra/ia/informe_diario.py --dry      # genera y muestra, NO envia
    python3 infra/ia/informe_diario.py            # genera y envia
    python3 infra/ia/informe_diario.py --fecha 2026-10-24 --dry

Autorizacion del dueno (2026-10-24): el texto de las conversaciones va COMPLETO a DeepSeek via Hermes para
que el informe sea fiable; sin enmascarar. No se guarda ningun dataset fuera de esta ejecucion.
"""
import argparse
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

ENV_PROD = Path.home() / '.config' / 'wacrm' / 'prod-db.env'
VAR_PROD = 'PROD_DATABASE_URL'
IMAGEN = 'postgres:17-alpine'
ENDPOINT = 'https://wacrm.onlinefreedom.site/api/internal/hermes/report'
ADMIN_PHONE = '5219622896918'  # "humbe"
MAX_TEXTO = 3500

SQL_DATASET = r"""
WITH hoy AS (
  SELECT COALESCE(:'fecha'::date, (now() AT TIME ZONE 'America/Guyana')::date) AS d
),
rango AS (
  SELECT ((d + time '09:00') AT TIME ZONE 'America/Guyana') AS ini,
         ((d + time '17:00') AT TIME ZONE 'America/Guyana') AS fin
    FROM hoy
),
msgs AS (
  SELECT m.conversation_id, m.sender_type, m.content_type, m.created_at,
         left(COALESCE(NULLIF(m.content_text, ''),
                       CASE WHEN m.content_type <> 'text' THEN '[media]' ELSE '' END), 600) AS texto
    FROM messages m, rango r
   WHERE m.created_at >= r.ini AND m.created_at < r.fin
),
conv AS (
  SELECT m.conversation_id,
         COALESCE(NULLIF(c.name, ''), c.phone) AS contacto,
         jsonb_agg(jsonb_build_object(
           'remite', m.sender_type, 'tipo', m.content_type,
           'hora', to_char(m.created_at AT TIME ZONE 'UTC', 'HH24:MI'),
           'texto', m.texto) ORDER BY m.created_at) AS mensajes
    FROM msgs m
    JOIN conversations v ON v.id = m.conversation_id
    JOIN contacts c ON c.id = v.contact_id
   GROUP BY 1, 2
),
ops AS (
  SELECT jsonb_agg(jsonb_build_object(
           'op', left(o.id::text, 8), 'servicio', o.service_type, 'estado', o.status,
           'origen_gyd', o.quoted_source_amount,
           'creada', to_char(o.created_at AT TIME ZONE 'UTC', 'HH24:MI'),
           'actualizada', to_char(o.updated_at AT TIME ZONE 'UTC', 'HH24:MI')) ORDER BY o.created_at) AS lista
    FROM remittance_operations o, rango r
   WHERE (o.created_at >= r.ini AND o.created_at < r.fin)
      OR (o.updated_at >= r.ini AND o.updated_at < r.fin)
),
tools AS (
  SELECT jsonb_object_agg(tool_name, n) AS lista
    FROM (SELECT l.tool_name, count(*) AS n
            FROM tool_execution_log l, rango r
           WHERE l.created_at >= r.ini AND l.created_at < r.fin
           GROUP BY 1) t
),
sin_respuesta AS (
  SELECT jsonb_agg(jsonb_build_object(
           'conv', left(u.conversation_id::text, 8), 'contacto', x.contacto,
           'hora', to_char(u.created_at AT TIME ZONE 'UTC', 'HH24:MI'),
           'texto', left(COALESCE(u.texto, '[media]'), 200)) ORDER BY u.created_at) AS lista
    FROM (
      SELECT m.*, row_number() OVER (PARTITION BY m.conversation_id ORDER BY m.created_at DESC) AS rn
        FROM msgs m
    ) u
    JOIN conv x ON x.conversation_id = u.conversation_id
   WHERE u.rn = 1 AND u.sender_type = 'customer'
     -- (sin permiso sobre cerebro_es_cortesia para el usuario de solo lectura)
     AND NOT (u.content_type = 'text' AND btrim(lower(COALESCE(u.texto, '')), E' \t\n.,!¡¿?:;-👍🙏😊😉✅❤️')
              ~ '^(|ok|oka|okay|okey|oki|vale|listo|dale|gra[cs]ias?|muchas gra[cs]ias?|perfecto|perfect|bien|bueno|entendido|entiendo|de acuerdo|thank you|thanks|thank u|ty|got it|understood|alright|sure|yes|yep|yeah|si|sí)$')
),
promesas AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object('conv', left(p.conversation_id::text, 8),
           'hora', to_char(p.message_created_at AT TIME ZONE 'UTC', 'HH24:MI'),
           'texto', left(p.content_excerpt, 200)) ORDER BY p.message_created_at), '[]'::jsonb) AS lista
    FROM cerebro_promesas_sin_escritura p, rango r
   WHERE p.message_created_at >= r.ini AND p.message_created_at < r.fin
),
ingesta AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object('conv', left(i.conversation_id::text, 8),
           'hora', to_char(i.message_created_at AT TIME ZONE 'UTC', 'HH24:MI')) ORDER BY i.message_created_at), '[]'::jsonb) AS lista
    FROM cerebro_ingesta_perdida i, rango r
   WHERE i.message_created_at >= r.ini AND i.message_created_at < r.fin
),
atascados AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object('conv', left(n.conversation_id::text, 8),
           'hora', to_char(n.created_at AT TIME ZONE 'UTC', 'HH24:MI')) ORDER BY n.created_at), '[]'::jsonb) AS lista
    FROM notifications n, rango r
   WHERE n.type = 'chat_atascado' AND n.created_at >= r.ini AND n.created_at < r.fin
)
SELECT jsonb_pretty(jsonb_build_object(
  'fecha', (SELECT d FROM hoy),
  'resumen', jsonb_build_object(
    'conversaciones', (SELECT count(*) FROM conv),
    'mensajes_cliente', (SELECT count(*) FROM msgs WHERE sender_type = 'customer'),
    'mensajes_bot', (SELECT count(*) FROM msgs WHERE sender_type = 'agent'),
    'operaciones', COALESCE((SELECT jsonb_array_length(lista) FROM ops), 0)),
  'conversaciones', COALESCE((SELECT jsonb_agg(jsonb_build_object('contacto', contacto, 'mensajes', mensajes)) FROM conv), '[]'::jsonb),
  'operaciones', COALESCE((SELECT lista FROM ops), '[]'::jsonb),
  'herramientas', COALESCE((SELECT lista FROM tools), '{}'::jsonb),
  'riesgos', jsonb_build_object(
    'sin_respuesta', COALESCE((SELECT lista FROM sin_respuesta), '[]'::jsonb),
    'promesas_sin_escritura', (SELECT lista FROM promesas),
    'ingesta_perdida', (SELECT lista FROM ingesta),
    'chats_atascados', (SELECT lista FROM atascados))
));
"""

PROMPT = """Eres Hermes, el asistente de negocio de Remesas Ya (remesas desde Guyana hacia Cuba, Mexico y Zelle).
Recibes el dataset de UN dia de negocio (09:00-17:00 hora de Guyana) con las conversaciones completas.

Escribe el INFORME DIARIO para el dueno, en espanol neutro, listo para WhatsApp. Estructura EXACTA:

1. RESUMEN DEL DIA: conversaciones, clientes atendidos, mensajes, operaciones creadas/completadas/incidencias.
2. QUE PIDIERON LOS CLIENTES: los temas mas frecuentes (tasas, Zelle, recargas, Mexico, quejas...) con conteos.
3. CASOS DE RIESGO: clientes sin respuesta, promesas sin escritura, depositos sin cruzar, chats atascados
   (usa las listas de "riesgos"; si estan vacias dilo en una linea).
4. LO QUE EL BOT NO SUPO RESOLVER: preguntas repetidas mal contestadas, derivaciones, confusiones.
5. 3-5 CONVERSACIONES A REVISAR: id corto (8 caracteres) y el motivo en una linea.

Reglas: nada de markdown de codigo; sin tablas; frases cortas; no inventes cifras que no esten en los datos;
si un dato no existe, di que no hay. Maximo 3000 caracteres. Empieza con "INFORME DIARIO Remesas Ya - <fecha>".

DATOS DEL DIA (JSON):
"""


class Error(Exception):
    pass


def psql(sql: str) -> str:
    cmd = ['docker', 'run', '--rm', '-i', '--env-file', str(ENV_PROD), IMAGEN, 'sh', '-c',
           f'psql -X -q -A -t "${VAR_PROD}" -v ON_ERROR_STOP=1 -f -']
    try:
        r = subprocess.run(cmd, input=sql.encode('utf-8'), capture_output=True, timeout=180)
    except OSError:
        raise Error('no se pudo ejecutar docker')
    except subprocess.TimeoutExpired:
        raise Error('tiempo agotado consultando la base')
    if r.returncode != 0:
        lineas = r.stderr.decode('utf-8', 'replace').strip().splitlines()
        raise Error(lineas[-1] if lineas else f'psql codigo {r.returncode}')
    return r.stdout.decode('utf-8', 'replace')


def secret() -> str:
    out = psql("SELECT valor FROM cerebro_config WHERE clave = 'notify_secret';").strip()
    if not out:
        raise Error('no encontre notify_secret')
    return out


def dataset(fecha: str | None) -> str:
    valor = f"'{fecha}'" if fecha else 'NULL'
    return psql(SQL_DATASET.replace(":'fecha'", valor)).strip()


def informe(datos: str) -> str:
    prompt = PROMPT + datos
    try:
        r = subprocess.run(['hermes', '-z', prompt, '-t', 'todo', '--in', '/tmp'],
                           capture_output=True, text=True, timeout=900)
    except OSError:
        raise Error('no se pudo ejecutar hermes')
    except subprocess.TimeoutExpired:
        raise Error('hermes tardo mas de 15 minutos')
    texto = (r.stdout or '').strip()
    if len(texto) < 200:
        raise Error(f'hermes devolvio una respuesta corta ({len(texto)} chars): {texto[:200]}')
    return texto


def enviar(texto: str, clave: str) -> dict:
    cuerpo = json.dumps({'text': texto[:MAX_TEXTO], 'phone': ADMIN_PHONE}).encode('utf-8')
    req = urllib.request.Request(
        ENDPOINT, data=cuerpo,
        headers={'Content-Type': 'application/json', 'x-cerebro-secret': clave})
    with urllib.request.urlopen(req, timeout=60) as res:
        return json.loads(res.read().decode('utf-8'))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry', action='store_true', help='genera y muestra; no envia')
    ap.add_argument('--fecha', default=None, help='YYYY-MM-DD (por defecto hoy en Guyana)')
    args = ap.parse_args()
    try:
        datos = dataset(args.fecha)
        if not datos:
            raise Error('la base devolvio un dataset vacio')
        texto = informe(datos)
        print(texto)
        if args.dry:
            print('\n[dry] no se envio.', file=sys.stderr)
            return 0
        res = enviar(texto, secret())
        print(f"\n[enviado] {json.dumps(res, ensure_ascii=False)}", file=sys.stderr)
        return 0
    except Error as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
