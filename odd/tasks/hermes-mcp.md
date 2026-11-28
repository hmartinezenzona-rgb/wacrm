# Hermes in the CRM — read-only MCP server

Status: in progress · Branch: feat/port-chat-operations-calculator · 2026-10-24

## Objective

Give Hermes (the admin business assistant) read-only tools over the CRM through MCP, so it can answer questions about conversations, operations, calculator, alerts and rates. The panel exposes an MCP endpoint; Hermes adds it with `hermes mcp add`. The chat section in the panel and the daily WhatsApp report come later on top of this.

## Design

- Six read-only DB functions (`hermes_*`, SECURITY DEFINER, service_role EXECUTE) do the querying and return compact JSON.
- `src/lib/hermes/mcp-tools.ts` registers the MCP tools against those RPCs (db injectable for tests).
- `POST /api/mcp` speaks MCP Streamable HTTP (web-standard transport) and is authenticated with a bearer token compared in constant time (cerebro_config `notify_secret` for v1).
- No writes anywhere; no customer data leaves the CRM through these tools except in the MCP answer to Hermes (owner authorized full text on 2026-10-24).

## Tools

1. `buscar_conversacion(consulta)` — phone digits, name, or conversation id prefix.
2. `leer_mensajes(conversacion, limite, desde)` — messages with sender/type/UTC time/text (media marked).
3. `listar_operaciones(conversacion?, desde?, hasta?)` — operations with status and amounts.
4. `ver_calculadora(desde?, hasta?)` — calculator entries and totals.
5. `alertas(desde?, hasta?)` — ingestion, promises, stuck chats, outbox.
6. `tasas_vigentes()` — published rates, ARQ rate, minimums.

## Tasks

- [ ] T1. Migration 314: the six `hermes_*` functions + rollback + assertion.
- [ ] T2. `src/lib/hermes/mcp-tools.ts` with the tool registrations (db injectable).
- [ ] T3. `POST /api/mcp` with bearer auth and the web-standard transport.
- [ ] T4. Test: tools/list and one tool through the SDK client + in-memory transport.
- [ ] T5. Staging cycle, tsc/tests, publish.
- [ ] T6. Add the server to Hermes (`hermes mcp add <url>`) and verify from the CLI.

## Checks

- `npx vitest run src/lib/hermes`
- `npx tsc --noEmit`
- Staging migration cycle for 314.
