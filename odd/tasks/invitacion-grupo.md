# Invitación al grupo de WhatsApp

Status: live in production (bot); template pending · Branch: feat/port-chat-operations-calculator · 2026-10-24

## Objective

Invite every NEW client (first message of their first conversation) to the Remesas Ya WhatsApp group, with the group name in bold and the exact invite link. Existing clients get the invitation through a Meta template (Marketing) used by a broadcast.

## Problem

The bot has no group invitation. The greeting rule already opens the first message of the day with the presentation; the invitation must be added once per new conversation, never repeated, and only for customers (an admin message is silenced and must not get it).

## Scope

- Cerebro: `Contexto conversacion` exposes `mensajes_cliente` (count of customer messages in the conversation); the Decisor appends a literal invitation note when that count is 1 and the sender is not admin.
- Meta template (Marketing, es) with the bold group name and a URL button, for the broadcast to existing clients. Created in WhatsApp Manager; the panel syncs it.
- No CRM code, no migration.

## Copy

Bot (new client, appended after the reply):

> Tenemos un grupo de WhatsApp de *Remesas Ya* donde compartimos tasas, promociones y avisos al instante. Únete aquí:
> https://chat.whatsapp.com/GFznWMcrlHa5RSBo76Vw81

Template body: `Hola {{1}}. En el grupo de WhatsApp de *Remesas Ya* compartimos tasas, promociones y avisos al instante. Únete y mantente al día.`
Button: `Unirme al grupo` → `https://chat.whatsapp.com/GFznWMcrlHa5RSBo76Vw81`

## Tasks

- [x] T1. Decisor: invitation note guarded by `!ctx.es_admin && Number(ctx.mensajes_cliente) === 1`; literal text and link.
  - Evidence: tests "la anade en el primer mensaje", "no la repite", "no se le manda a un admin".
- [x] T2. `Contexto conversacion`: `mensajes_cliente` added in staging and production.
- [x] T3. Harness: md5 pin 13fae851; `npx vitest run pruebas/decisor` 65/65.
- [x] T4. Staging: Decisor published and Contexto patched; versionId == activeVersionId (dc232d4e); harness 65/65.
- [x] T5. Production published (owner go-ahead): Contexto patched, Decisor md5 13fae851, versionId == activeVersionId; `comparar` shows Contexto and Decisor equal across environments.
  - Evidence: production backup 20261024-130850; live proof pending a genuinely new contact.
- [ ] T6. Template copy handed to the owner for WhatsApp Manager; then broadcast to existing clients from the panel.

## Checks

- `npx vitest run pruebas/decisor`
- `python3 infra/n8n/cerebro_n8n.py estado staging`
- `python3 infra/n8n/cerebro_n8n.py comparar`

## Verification evidence

- Pending.
