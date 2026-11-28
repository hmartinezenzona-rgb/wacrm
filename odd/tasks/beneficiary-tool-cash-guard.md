# The card beneficiary tool must not open a card operation on a cash send

## Problem (production, 2026-11-05)

Conversation 1232671b: a cash USD operation e976e1fc (`delivery_method = efectivo_usd`) was open. The Decisor added
card-oriented notes ("Falta la tarjeta ... llama gestionar_beneficiario con el celular y pide la tarjeta") and the agent
called the n8n tool `gestionar_beneficiario(nombre, tarjeta = '', celular)` (execution 648684). The SQL behind the tool
created a NEW operation 16a90b56 (no delivery_method, cuban_card beneficiary) and answered "FALTA: la tarjeta", so the bot
asked the customer for a card number. The data was corrected by hand (audits 53e64ad1, e01031ea).

## Owner decision

2026-11-05: fix it only in the database tool ("haz el arreglo solo en la herramienta de la base de datos"); the Decisor
file is NOT touched (it holds another session's uncommitted changes).

## Scope

- T1 Migration 353 (staging first): in the SQL function the `gestionar_beneficiario` tool calls (find it in the n8n
  snapshots under `infra/n8n/snapshots/` and in `supabase/migrations/`; read the live body with `pg_get_functiondef`),
  when the call carries NO card and the conversation has an open (not completed/cancelled) cash operation
  (`delivery_method = 'efectivo_usd'`, or the cash rail by whatever the function uses to decide the rail):
  - do NOT create a new operation and do NOT add a cuban_card beneficiary;
  - save the given name and phone on that cash operation's live beneficiary only where they are empty (never overwrite
    a value a person or the carnet flow set), with the same audit style the cash data flow uses;
  - answer the agent in the same output format the tool uses today, saying it is a cash send, what was saved, what is
    still missing for cash (name, address, carnet photo — whichever is empty) and, explicitly, "NO pidas tarjeta: es
    entrega en efectivo".
  Every other case (a card given, no cash operation open, recharges) behaves exactly as today.
- T2 Production: previa, apply, verify after the owner's go-ahead.

## Constraints

- Do not touch `pruebas/decisor/*` or `odd/tasks/bot-brevedad.md` (another session's uncommitted files).
- No n8n changes. No real customer data in tests, fixtures or commits.
- Migration rules: staging first; ROLLBACK file; self-reverting assertion ending `ALL PASS (rolled back on purpose)`.

## TDD

Strict, on. The staging assertion is the test (RED before the migration).

## Tasks

- [x] T1 Migration 353 on staging: no stray card operation on a cash send. Evidence: RED = new assertion failed on the old body (case a1, a second operation was created); GREEN = `staging-migracion.sh aplicar`: dry-run OK, apply OK, assertion OK, rollback OK (md5 equal to previous); `relacionadas` TOTAL 27, SAME 27, DIFF 0.
- [x] T2 Production 2026-11-05, owner go-ahead ("si"): 353 applied (20261105230638), verificar 1/1 EQUAL (e902896c).
- [x] T3 (code done, deploy pending) Root cause in the Decisor (owner 2026-11-05: "el arreglo creo que deberia atacar la causa real"). The LIVE Decisor
  is `pruebas/decisor/produccion/decisor.jscode` (md5 982b147c = production versionId 6feb0fd1), NOT
  `pruebas/decisor/decisor.jscode` (that one holds the other session's uncommitted changes and stays untouched). When
  `ctx.riel_operacion` is the cash rail (efectivo_usd), the card notes "Celular cubano detectado ... Falta la tarjeta
  ESCRITA" and "TODAVIA NO HAY BENEFICIARIO REGISTRADO ... llama gestionar_beneficiario ... pide la tarjeta" are not
  emitted; instead one cash note: entrega en efectivo, NO pidas tarjeta, pide solo lo que falte (nombre completo,
  direccion, foto del carnet). Tests in `pruebas/decisor/produccion/decisor-produccion.test.ts`, md5 pin in
  `pruebas/decisor/produccion/correr.ts`. Deploy: staging with `CEREBRO_DECISOR_FILE` pointing at the produccion file,
  production after go-ahead.

## Progress

- 2026-11-05 created. RDD off.
- 2026-11-05 T1 done on staging: function `cerebro_guardar_beneficiario(p_conv, p_nombre, p_tarjeta, p_celular, p_exec, p_op, p_tool, p_posicion, p_tipo)` (the n8n tool `gestionar_beneficiario` calls it with 5 args). New branch calls `crm_registrar_datos_entrega_efectivo` so storage and audit match the cash flow. Cash rule: empty card, a name or phone given, no position/type, and an open `remittance` operation with `delivery_method = 'efectivo_usd'` (newest; must equal p_op when one is named). Production not touched.
- 2026-11-05 T3 code: produccion Decisor reads `ctx.riel_operacion === 'efectivo_usd'` early (`rielEfectivo`); on cash it skips the "Celular cubano detectado ... Falta la tarjeta" note and replaces the card-oriented "TODAVIA NO HAY BENEFICIARIO REGISTRADO" note with one "ENTREGA EN EFECTIVO" note. RED = new cash test failed on the old file; GREEN = `vitest run pruebas/decisor/produccion` 69/69, full suite 273 files / 3794 passed. New md5 9150c4d8 (was 982b147c). Deploy (staging with CEREBRO_DECISOR_FILE, then production) pending.

- 2026-11-05 T3 deployed to PRODUCTION after the owner's go-ahead (staging skipped: its Decisor is the other session's 243f6cfd). Backup produccion-jEzlVLCLUaJhVwzs-6feb0fd1-...-20261105-170619.json; versionId 6feb0fd1 -> 158fdc43 (= activeVersionId); Decisor 982b147c -> 9150c4d8. Rollback: `cerebro_n8n.py restaurar produccion <backup> --esperado 158fdc43`.
