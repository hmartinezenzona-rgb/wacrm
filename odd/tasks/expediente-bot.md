# Phase 4b: the bot asks when the case is in conflict

Status: DONE (2026-10-26): migration 333 applied in production (version 20261026215718, verified
1/1) and the Decisor published (versionId `6181706c-7201-4d19-bf7e-4d02f1640058`, md5 `28fe7346`,
repo match). Objective: when the funding case is in incident, the bot must stop promising the
transfer, ask the customer to confirm the route, and leave the resolution to an operator.

## Why

Phase 3 blocks the delivery and phase 4a shows the incident in the panel, but the bot did not know:
it could keep saying the send was ready or keep asking for data while the money was blocked. The
customer needs a short question, not a silent block.

## What

- `cerebro_resolver_servicio` (migration 333) returns an `expediente` key: the active case's status,
  note and verified/assigned/available GYD, or null. A closed case is not exposed.
- The Decisor adds a final `EXPEDIENTE EN CONFLICTO` note when `expediente.estado = 'incident'`:
  delivery is blocked, it must ask one short question to confirm the card's route, must not promise a
  transfer or a deadline, must not change the service or call `cambiar_servicio`/`repartir_envio`,
  and an operator reviews it. The semantic plan also forbids `prometer_transferencia`.
- The Decisor md5 pin in `correr.ts` is updated to the new file.

## Tasks

- [x] T1. SQL assertion `expediente-en-resolver.sql` with RED on the staging base.
- [x] T2. Migration 333 adding the `expediente` key to the resolver.
- [x] T3. Staging cycle.
- [x] T4. Decisor note + tests + md5 pin.
- [x] T5. Publish the Decisor to staging and verify.
- [x] T6. Production: apply 333, publish the Decisor, verify, update docs.
- [x] T7. Production `verificar` + `comparar` staging/production.

## Verification

- SQL: `infra/db/staging-migracion.sh aplicar supabase/migrations/333_expediente_en_resolver.sql
  supabase/staging/assertions/expediente-en-resolver.sql
  supabase/migrations/ROLLBACK-333-expediente-en-resolver.sql cerebro_resolver_servicio`.
- Decisor: `npx vitest run pruebas/decisor`.
- Staging publish: `cerebro_n8n.py publicar-decisor staging --esperado <live md5>` and `estado`.
- Production: the same SQL `previa`/`aplicar`/`verificar`, then the Decisor publish with a fresh
  `estado produccion` md5 and the owner's go-ahead.

## Evidence

- T1 (2026-10-26): RED on the staging base: `case 1: the resolver did not expose the case`.
- T3: `dry-run OK`, `apply OK`, `assertion OK`, `rollback OK (md5 igual al previo)`;
  `cerebro_resolver_servicio f957d2554225`.
- T4: `npx vitest run pruebas/decisor` → 83/83 passed; Decisor md5
  `28fe7346dfeab51cdcf8434e54c654a0`.
- T5: staging backup `staging-U52y1kSNvhgxvWeb-3fb7d574-...-20261026-155205.json`; publish →
  versionId `0c4e94c9-00a2-4027-9a39-4387c4bea2c8`, activeVersionId the same, 132 nodes,
  Decisor md5 `28fe7346`, repo match `yes`.
- The staging Cerebro is never executed (it shares production's WhatsApp token); the note is covered
  by the Decisor harness and the resolver by the SQL assertion.
- T6 (2026-10-26): `aplicar 333` → `OK 333_expediente_en_resolver 20261026215718`; `verificar` →
  `VERIFICADO: 1/1 iguales`. Production backup
  `produccion-jEzlVLCLUaJhVwzs-f2b5f502-...-20261026-155728.json`; `publicar-decisor produccion` →
  versionId `6181706c-7201-4d19-bf7e-4d02f1640058`, 131 nodes, Decisor md5 `28fe7346`, repo match
  `yes`.
- T7 (2026-10-26): `comparar` lists only environment nodes (Avisar espera, Confirmar al admin,
  Despertar al enviador, Responder por WaCRM, Validar evento, Webhook WaCRM) and the staging-only
  DeepSeek Web Search; the Decisor matches in both environments.

## Decisions

- The case is exposed only while it is active; a closed case is history and does not block.
- The bot never resolves the conflict or changes the service; the operator does it in the panel.
- The raw note may mention a prefix; the instruction tells the model to translate it into a short
  customer question and not to expose internal ids.
