#!/usr/bin/env python3
"""Create a staging-only Cerebro simulator workflow.

Clones the current staging Cerebro and replaces the three CRM send nodes
(Responder por WaCRM, Avisar espera al cliente, Confirmar al admin) with a
message insert and a no-op, so no WhatsApp message can leave. The clone is a
separate workflow with a random webhook path and a local header token; it is
never the staging Cerebro itself.
"""
import copy
import json
import os
import secrets
import sys
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'infra' / 'n8n'))
from cerebro_n8n import api_request, get_base_url, load_api_key  # noqa: E402

BACKUP_DIR = Path.home() / 'cerebro-fase1' / 'respaldos-n8n'
ENV_FILE = Path.home() / '.config' / 'wacrm' / 'simulador.env'

backup = sorted(BACKUP_DIR.glob('staging-U52y1kSNvhgxvWeb-*.json'), key=os.path.getmtime)[-1]
wf = json.loads(backup.read_text())
name = 'SIMULADOR Cerebro (staging)'
path = 'simulador-cerebro-' + uuid.uuid4().hex[:12]
token = secrets.token_hex(24)

nodes = copy.deepcopy(wf['nodes'])
by_name = {n['name']: n for n in nodes}
postgres = by_name['Guardar evento']
noop = by_name['SKIP - no responder']

# Webhook: unique path. Validar evento: accept the simulator header, no secret.
by_name['Webhook WaCRM']['parameters']['path'] = path
by_name['Validar evento']['parameters']['jsCode'] = (
    "const req = $input.first().json;\n"
    "const headers = req.headers || {};\n"
    "if ((headers['x-simulador-token'] || '').toString() !== '" + token + "') { return []; }\n"
    "let body = req.body;\n"
    "if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { return []; } }\n"
    "body = body || {};\n"
    "const d = body.data ?? {};\n"
    "if (!d.conversation_id) { return []; }\n"
    "if (body.event !== 'message.received') { return []; }\n"
    "return [{ json: { conversation_id: d.conversation_id, tipo: (d.content_type ?? 'text').toString(), "
    "texto: (d.text ?? '').toString(), wamid: (d.whatsapp_message_id ?? '').toString(), "
    "reintento: false, firma: 'simulador:' + (d.whatsapp_message_id ?? Date.now()).toString() } }];\n"
)

# The bot's reply is written to messages, never sent.
responder = by_name['Responder por WaCRM']
responder['type'] = 'n8n-nodes-base.postgres'
responder['typeVersion'] = postgres['typeVersion']
responder['parameters'] = {
    'operation': 'executeQuery',
    'query': ("INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, message_id, ai_generated) "
              "VALUES ($1::uuid, 'bot', 'text', $2::text, 'sent', 'SIM-' || gen_random_uuid()::text, true) RETURNING id;"),
    'options': {'queryReplacement': "={{ [$('Decisor').item.json.conversation_id, $('Normalizar formato').item.json.output] }}"},
}
responder['credentials'] = copy.deepcopy(postgres['credentials'])

# The wait notice, the admin confirmation and the whole outbox/direct-send path are not sent.
# The real workflow replies through "Encolar en outbox" -> "Enviar directo?" -> "Responder por WaCRM"
# (true) or "Despertar al enviador" (false); the first version of this clone missed the outbox and
# tried to send through it. The no-op queue and the result node remove every send path.
for n in ('Avisar espera al cliente', 'Confirmar al admin', 'Encolar en outbox',
          'Resultado del envio', 'Despertar al enviador'):
    node = by_name[n]
    node['type'] = 'n8n-nodes-base.noOp'
    node['typeVersion'] = noop['typeVersion']
    node['parameters'] = {}
    node.pop('credentials', None)

# Always take the direct branch, which is now the message insert.
by_name['Enviar directo?']['parameters']['conditions']['conditions'][0]['leftValue'] = '={{ true }}'

body = {
    'name': name,
    'nodes': nodes,
    'connections': wf['connections'],
    'settings': wf.get('settings', {}),
}
base = get_base_url()
key = load_api_key()
created = api_request('POST', '/api/v1/workflows', base, key, body=body)
wid = created.get('id') or created.get('data', {}).get('id')
if not wid:
    sys.exit('no workflow id in the create response')
api_request('POST', f'/api/v1/workflows/{wid}/activate', base, key, body={})

ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
ENV_FILE.write_text(
    f"SIMULADOR_WEBHOOK_URL={base}/webhook/{path}\n"
    f"SIMULADOR_TOKEN={token}\n"
    f"SIMULADOR_WORKFLOW_ID={wid}\n"
)
ENV_FILE.chmod(0o600)
print('workflow_id', wid)
print('webhook', f'{base}/webhook/{path}')
print('nodes', len(nodes))
print('env', ENV_FILE)
