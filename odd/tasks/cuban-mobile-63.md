# Cuban mobiles starting with 63

## Objective
Accept Cuban mobile numbers that start with 63 everywhere the system recognises a beneficiary's phone.

## Problem / why
Since 2023-12-30 ETECSA gives new mobile lines numbers that start with 63. They are 8 digits, written
+53 63XX XXXX. Existing lines keep the 5 prefix. Sources: Cubadebate 2023-12-30 and Wikipedia
"Telephone numbers in Cuba", which lists mobile codes 5 and 63.

The system only accepts 5xxxxxxx:
- Real case, conversation 54454232 (2026-08-21): the bot rejected 63691728 six times. The customer
  insisted, and the team completed the transfer by hand.
- Production chats hold 4 distinct 63 numbers, in 4 chats. None of them was stored as a
  beneficiary phone.

## Rule
A Cuban mobile is 8 digits that start with 5 or with 63. It may also be written 53+8 or 0053+8.
Other numbers starting with 6 stay rejected (zero-error bar).

## Scope (authorized by the user, 2026-09-27: "si aplicalo")
- DB: `cerebro_aplicar_reparto` phone check (`^5[0-9]{7}$`), in migration 130.
- Reparto detector: `celularDe` in `~/cerebro-fase1/pruebas/nodo-repartos-automaticos.js`.
- Cerebro (prod jEzlVLCLUaJhVwzs / staging U52y1kSNvhgxvWeb):
  - `Snapshot final`: text runs and the vision phone;
  - `Evaluar completitud`;
  - the `Decisor` note to the agent;
  - the 4 vision prompts.
- Not changed:
  - the Zelle/US detection (`normUS`): 53+63xxxxxx still starts with 5, so it is never taken
    as a US number;
  - `registrar_reparto_multiple`, which only checks 8 digits.

## TDD
- Mode: strict, from the global config.
- Runners:
  - DB: `supabase/staging/assertions/reparto-auto.sql` (BEGIN; \i; ROLLBACK) on wacrm-ensayo, then
    staging.
  - Detector: `node banco-repartos.js` plus a unit check of `celularDe`.
  - Cerebro nodes: a local node harness running the live node code.

## Tasks
- [x] C1 — Migration 130: `cerebro_aplicar_reparto` accepts 63xxxxxx.
  - Assertion case RED, then GREEN.
  - Apply on ensayo, staging and prod.
- [x] C2 — Detector `celularDe` accepts 63.
  - Unit check RED, then GREEN; bench stays 8/8 with 0 wrong.
  - Deploy both reparto workflows.
- [x] C3 — Cerebro nodes accept 63: Snapshot final, Evaluar completitud, Decisor note, vision prompts.
  - Local harness RED, then GREEN.
  - Staging first, then prod, with backups.

## Acceptance
- A 63xxxxxx phone is recognised as a Cuban mobile by the bot, the vision and the automatic reparto.
- 5xxxxxxx behaves exactly as before.
- Other 6xxxxxxx numbers are still rejected.

## Progress
- 2026-09-28 C1 — migration 130.
  - Assertion cases 12–13.
    - RED: "case 12: ... formato".
    - GREEN: 13/13 on ensayo and staging.
    - The rollback re-applies 129; checked (case 12 fails again), then 130 was re-applied.
  - Production applied; md5 356177dc… equals staging. Commit 532c3ad.
- 2026-09-28 C2 — detector `celularDe` via `esMovilCU` (5xxxxxxx | 63xxxxxx, also 53/0053 prefixed).
  - Unit check `test-celular-cubano.js`: RED 6/10, then GREEN 10/10.
  - Bench still 8/8 exact, 0 wrong, over 81 deposits.
  - Prod dry run: 0 repartos.
  - Both reparto workflows on v6; the code equals the file.
  - Rollback copies: `ROLLBACK-repartos-*-antes-movil63.json`.
- 2026-09-28 C3 — Cerebro.
  - Patch `pruebas/parche-movil-63.py`: exact replacements, each checked for count.
  - Bench `pruebas/banco-movil-63.js` runs the REAL node code.
    - RED on live prod: Snapshot x4, Evaluar completitud, Decisor, 4 vision prompts.
    - GREEN on the candidate.
  - `diff-solo-nodos.py`: only the 7 intended nodes change; connections and settings are identical.
  - Deployed to staging, then prod; the live code of both passes the bench.
  - Rollback copies: `ROLLBACK-cerebro-{staging,PRODUCCION}-antes-movil63.json`.
  - Pending: watch the first prod executions after deploy.
  - No staging end-to-end: the Cerebro only runs from the WhatsApp webhook.
