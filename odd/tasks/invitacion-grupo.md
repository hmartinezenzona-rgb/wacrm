# Invitación al grupo de WhatsApp

Status: in progress · Branch: feat/port-chat-operations-calculator · 2026-10-24

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

- [ ] T1. Decisor: invitation note guarded by `!ctx.es_admin && Number(ctx.mensajes_cliente) === 1`; literal text and link.
- [ ] T2. `Contexto conversacion`: add `mensajes_cliente` to the query (staging, then production).
- [ ] T3. Harness: md5 pin updated; `npx vitest run pruebas/decisor` green.
- [ ] T4. Staging: publish Decisor and patch Contexto; verify `estado` (versionId == activeVersionId) and the query md5.
- [ ] T5. Production only with the owner's go-ahead; verify with a real new contact.
- [ ] T6. Template copy handed to the owner for WhatsApp Manager; then broadcast to existing clients from the panel.

## Checks

- `npx vitest run pruebas/decisor`
- `python3 infra/n8n/cerebro_n8n.py estado staging`
- `python3 infra/n8n/cerebro_n8n.py comparar`

## Verification evidence

- Pending.
