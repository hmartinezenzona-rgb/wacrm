# Feature: parts note uses the group deposit; comparison quotes do not open operations

## Objective
Two defects from the Yoandrys conversation (a6d28009, 2026-10-26) must not repeat:
1. The bot told the customer that 10,000 GYD were missing for the card when the 285,000 GYD deposit covered both
   parts (275,000 Zelle + 10,000 card).
2. Quoting the four channels for one send left a phantom Clasica operation (286,000 GYD) that contaminated the
   split and the owner had to cancel.

## Root causes (verified)
- The Decisor's `PARTES ACORDADAS` note computed the registered deposit as the sum of each holder's
  `dinero_gyd`. After `repartir_envio`, the holder's `dinero_gyd` is its own part (275,000), not the deposit
  (285,000), so the note contradicted `ENVIO MIXTO` and said 10,000 were missing.
- `cerebro_cotizar` names a service and `_cerebro_declarar_implicito` records the quoted amount through
  `_cerebro_operacion_declarada` + `_cerebro_fijar_monto_acordado`, opening one operation per quoted channel. The
  four-channel quote at 13:11 created the Zelle operation (275,000) and the Clasica one (286,000).

## Scope
- Migration 327: the resolver returns `deposito_grupo_gyd` (the group's actual verified money); an implicit quote
  no longer declares or opens an operation while an uncommitted operation of another service is open.
- Decisor: `PARTES ACORDADAS` uses `deposito_grupo_gyd` when present.
- Tests: Decisor vitest for both branches of the note; staging assertion for the resolver field and the implicit
  declaration guard (explicit declaration still works).
- Out of scope: changing the four-channel quote flow in the prompt; the DB guard leaves the first operation as
  the anchor and an explicit `cambiar_servicio` still retypes it.

## Constraints
- Staging first; production with an explicit go-ahead.
- The first quoted channel still opens the anchor operation (intended by 289); only the second and later
  comparison quotes are ignored.

## Tasks
- [x] T1. Diagnose both causes from the conversation, the Decisor notes, and the audit rows (13:11, 13:36, 13:37).
- [x] T2. Migration 327 + ROLLBACK-327 + assertion `nota-partes-y-cotizaciones.sql`.
- [x] T3. Staging: dry-run/apply/assertion/rollback OK; resolver md5 4753bf58, declaration md5 e9bb02a3.
- [x] T4. Decisor note uses `deposito_grupo_gyd`; vitest 81/81; staging Decisor versionId 3fb7d574, md5 76cb41af.
- [x] T5. Applied in production: 327_nota_partes_y_cotizaciones 20261026155931 (verificar 2/2, prod=stg); Decisor versionId f2b5f502-e240-4d46-9f32-a969ffe87b4a, md5 76cb41af.
- [x] T6. Staging simulation: after a Zelle quote and an ignored Clasica comparison, card data lands on an
  operation whose rail is cuban_card and no Clasica operation exists (cause A of the conversation).
- [x] T7. Migration 328 (`crm_entregar_operacion`): a Zelle operation cannot be delivered while its vigente
  recipients do not add up. Two protections: applies only when every recipient has an amount, and compares whole
  dollars. Staging: dry-run/apply/assertion/rollback OK; the assertion blocks 800+200 of 1,100, delivers after
  adding 100, and skips the gate when an amount is null.
- [ ] T8. Owner go-ahead; apply 328 to production.
- [ ] T9. Decide whether to correct the completed e4c2a15b record (1,000 of 1,100 USD in recipients).

## Acceptance criteria
- With a group of 275,000 + 10,000 and a 285,000 deposit, `deposito_grupo_gyd` = 285,000 and the note says
  "Cubre todo lo acordado".
- With an open uncommitted Zelle operation, an implicit Clasica quote returns false and creates no operation; an
  explicit declaration creates it.
