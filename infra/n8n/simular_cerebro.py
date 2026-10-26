#!/usr/bin/env python3
"""Run one synthetic turn through the staging simulator workflow.

Creates a PRUEBA conversation and a customer message in staging, posts the
signed webhook to the simulator clone, waits for the bot's reply in messages,
prints it, and (unless --conservar) cleans the PRUEBA rows. It never calls
WhatsApp: the clone writes the reply to messages instead of the CRM send API.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ENV_SIM = Path.home() / '.config' / 'wacrm' / 'simulador.env'
ENV_STAGING = REPO / '.env.staging'


def psql(sql: str) -> str:
    out = subprocess.run(
        ['docker', 'run', '--rm', '-i', '--env-file', str(ENV_STAGING), 'postgres:17',
         'sh', '-c', 'psql -X -q -A -t "$CRM_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f -'],
        input=sql, text=True, capture_output=True, cwd=REPO,
    )
    if out.returncode != 0:
        raise SystemExit(f'psql failed: {out.stderr.strip()[-800:]}')
    return out.stdout.strip()


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip()
    return env


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--texto', default='Hola, cuánto llegan por 13,000 GYD a Zelle?')
    ap.add_argument('--telefono', default='59902539999')
    ap.add_argument('--conservar', action='store_true', help='do not clean the PRUEBA rows')
    args = ap.parse_args()

    sim = load_env(ENV_SIM)
    url = sim.get('SIMULADOR_WEBHOOK_URL')
    token = sim.get('SIMULADOR_TOKEN')
    if not url or not token:
        raise SystemExit(f'missing SIMULADOR_* in {ENV_SIM}')

    exists = psql(f"SELECT count(*) FROM contacts WHERE phone = '{args.telefono}';")
    if exists and exists != '0':
        raise SystemExit(f'phone {args.telefono} already used; pass another --telefono')

    wamid = f'SIM-{int(time.time())}'
    text_sql = args.texto.replace("'", "''")
    conv = psql(f"""
WITH u AS (
  SELECT p.user_id, p.account_id
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1
), ct AS (
  INSERT INTO contacts (user_id, account_id, phone, name)
  SELECT u.user_id, u.account_id, '{args.telefono}', 'PRUEBA simulador' FROM u
  RETURNING id, user_id, account_id
), cv AS (
  INSERT INTO conversations (user_id, account_id, contact_id, status, ai_autoreply_disabled, last_message_text, last_message_at)
  SELECT ct.user_id, ct.account_id, ct.id, 'open', false, '{text_sql}', now() FROM ct
  RETURNING id
)
SELECT id FROM cv;
""").strip()
    if not conv:
        raise SystemExit('fixture failed: no conversation id')
    psql(f"""
INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, message_id, ai_generated)
VALUES ('{conv}', 'customer', 'text', '{text_sql}', 'delivered', '{wamid}', false);
""")
    print('conversation', conv)
    print('customer    ', args.texto)

    payload = json.dumps({
        'event': 'message.received',
        'data': {'conversation_id': conv, 'content_type': 'text', 'text': args.texto,
                 'whatsapp_message_id': wamid},
    }).encode()
    req = urllib.request.Request(url, data=payload, method='POST',
                                 headers={'Content-Type': 'application/json',
                                          'x-simulador-token': token})
    with urllib.request.urlopen(req, timeout=30) as resp:
        print('webhook     ', resp.status)

    deadline = time.time() + 120
    reply = None
    while time.time() < deadline:
        reply = psql(f"""
SELECT content_text FROM messages
 WHERE conversation_id = '{conv}' AND sender_type = 'bot'
 ORDER BY created_at DESC LIMIT 1;
""")
        if reply:
            break
        time.sleep(3)
    if reply:
        print('bot         ', reply)
    else:
        print('bot         (sin respuesta en 120 s)')

    if not args.conservar:
        # The simulator may have created a funding case; delete it before the
        # deposits/messages that case_deposits references.
        psql(f"""
BEGIN;
DELETE FROM funding_case WHERE conversation_id = '{conv}';
DELETE FROM message_outbox WHERE telefono_e164 = '+{args.telefono}';
DELETE FROM cerebro_ejecuciones WHERE conversation_id = '{conv}';
DELETE FROM tool_execution_log WHERE conversation_id = '{conv}';
DELETE FROM cerebro_memoria WHERE session_id = '{conv}';
DELETE FROM cerebro_webhook_nonces WHERE firma LIKE 'simulador%';
DELETE FROM cerebro_objetivo_envio WHERE conversation_id = '{conv}';
DELETE FROM session_events WHERE conversation_id = '{conv}';
DELETE FROM messages WHERE conversation_id = '{conv}';
DELETE FROM conversations WHERE id = '{conv}';
DELETE FROM contacts WHERE phone = '{args.telefono}';
COMMIT;
""")
        left = psql(f"SELECT count(*) FROM contacts WHERE phone = '{args.telefono}';")
        print('cleaned     ', 'yes' if left == '0' else f'NO ({left} contacts left)')
    else:
        print('kept        ', conv)

    return 0 if reply else 1


if __name__ == '__main__':
    sys.exit(main())
