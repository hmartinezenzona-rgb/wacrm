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

## 2026-11-24 — botón interactivo para clientes nuevos (sin plantilla)

Decisión: no se envía una plantilla Marketing por cada cliente nuevo. El primer mensaje del cliente abre la ventana de 24 h, así que el webhook manda un **mensaje interactivo `cta_url`** (sin aprobación de Meta) con el botón “Unirme al grupo” apuntando al `/grupo` del panel.

- [x] Soporte `cta_url` en el núcleo de mensajes interactivos + tests.
- [x] Webhook: al primer mensaje de un cliente nuevo, envía la invitación con tres guardas: flag `cerebro_config.grupo_boton` (apagado por defecto), contacto sin etiqueta Admin, y sin un `cta_url` previo en el hilo.
- [x] Panel de producción con el código, **flag apagado** (BUILD_ID Md8Guw4ttKvI7IZkL6YgR, rollback 42f5a1e2).
- [x] Decisor de staging sin la invitación en texto (md5 d64e8009, versionId 105ef1da, repo match).
- [ ] Producción: publicar el Decisor sin el texto y encender `grupo_boton='si'` (requiere go-ahead). Probar con un contacto nuevo.
- [ ] T6 original (plantilla + broadcast a existentes): la plantilla debe apuntar al `/grupo`, no a `chat.whatsapp.com` (Meta rechaza ese host en botones).

Nota: el staging local no recibe webhooks de Meta; la prueba real del botón se hace en producción con un contacto nuevo.
