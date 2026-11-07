# Feature: a multi-card reparto must add up to the verified deposit

## Objective
The amounts saved for each card of a reparto (2-3 Cuban cards, CUP or USD Clásica/Tropical) can never contradict
the money the customer actually deposited. The guarantee lives in the database, not in an instruction the model can
ignore.

## Problem / why (root cause, 2026-11-07)
- 96d81952 (exec 668756): verified deposit 10,000 GYD; the customer wrote "10.000 más para ponerle 5 a cada tarjeta".
  The Decisor regex (g82, decisor.jscode ~339-400) kept only 10000, attached "cada" to it and noted 10,000 GYD per
  card; the bot saved 36,000 CUP x2 (72,000 CUP for a 36,000 CUP deposit). Correct: 18,000 each.
- f80a33a0 (execs 666918/666930): verified deposit 15,000 GYD; "Son 3 tarjetas 15mil a cada una" became 45,000 GYD
  in the note, then 15,000 CUP x3 saved without conversion (45,000 of 54,000 CUP). The team fixed it by hand.
- Root cause: per-card amounts flow free text -> Decisor regex -> model -> tool `registrar_reparto_multiple` ->
  `cerebro_guardar_reparto` (184/284/353; live md5 346793f8), which accepts any amount and never reads the deposit or
  the rate. Nothing in the chain checks the invariant "parts add up to the money".
- Precedent: 335_zelle_amounts_within_deposit.sql refuses Zelle amounts above the deposit with a clear message.
  `cerebro_aplicar_reparto` (215) has the exact arithmetic but no live caller.

## Owner decisions
- 2026-11-07: root-cause fix, not a patch ("no quiero parches, quiero solución de raíz").
- 2026-11-07: when the cards add up to LESS than the deposit, the bot asks the customer to distribute the whole
  deposit or to say what to do with the leftover. The reparto is not complete until that is settled.

## Claude defaults (stated to the owner)
- Base: the operation's own `quoted_source_amount` once its deposit is verified (status ready_to_transfer or
  transferring, or `cerebro_fondos_operacion` covered); for a mixed group that is this operation's part.
- Rate: the rate the bot quotes with: CUP = round(GYD x crm_tasa_vigente('gyd')); Clásica/Tropical USD =
  floor(GYD / crm_tasa_vigente('usd')); a reparto mixing CUP and USD parts is compared in GYD. Exact figures (5 of the
  6 repartos of the last 30 days were exact); tolerance only for per-card rounding (1 CUP per card).
- Over the total: nothing is saved; the tool returns the available total and the current sum.
- Partial amounts: saved; the tool returns what is left for the other cards.
- Complete but under the total: saved, but the reply says FALTA "repartir los X CUP restantes o decir qué hacer con
  ese monto" (owner decision).
- Deposit verified after the reparto was saved: verification is never blocked; the mismatch reaches the bot through
  the conversation context so it asks the customer.
- Card or phone patches with empty amounts (gestionar_beneficiario path) behave as today.
- With the deposit verified, the Decisor stops guessing per-card amounts from regex and states the deposit-derived
  totals instead.

## Scope
In: migration(s) 358+ with ROLLBACK and staging assertions; Contexto conversacion field; Decisor (production lineage
pruebas/decisor/produccion/decisor.jscode) and its tests; staging; production with go-ahead.
Out: the orphan cerebro_aplicar_reparto; Zelle (already guarded by 335); the panel UI.

## Constraints
- Staging first; production only with the owner's explicit go-ahead. Read LIVE bodies before redefining.
- Strict TDD: SQL assertions on staging inside rolled-back transactions (RED then GREEN); Decisor via
  `npx vitest run pruebas/decisor/produccion`. Run related assertions (`staging-migracion.sh relacionadas`).
- Never touch the other session's files (pruebas/decisor/decisor.jscode, correr.ts, decisor-notas.test.ts at the
  pruebas/decisor root, odd/tasks/bot-brevedad.md). Never execute n8n workflows. No AI attribution in commits.
- RDD off. TDD on (user global config), runner npm test / vitest.

## Tasks
- [x] T1 (28ae52d) Migration 358: reparto total helper (available GYD/CUP/USD for an operation, null when not verified) and the
      guard inside cerebro_guardar_reparto (over -> refuse, partial -> remaining, complete-under -> FALTA leftover);
      ROLLBACK; assertion (both 2026-11-07 cases as fixtures, partial, mixed CUP+USD, unverified op unchanged,
      empty-amount patch unchanged)
- [ ] T2 Context: a `reparto_cuadre` field for the open reparto (available, sum, difference) exposed by
      Contexto conversacion (SQL function + node query, staging then production)
- [ ] T3 Decisor: with a verified deposit and a reparto, no g82 per-card guessing; a note with the deposit-derived
      totals and the mismatch from ctx.reparto_cuadre; tests with the two real cases
- [ ] T4 Staging: apply, assertions, related assertions, Contexto node on staging; owner check if wanted
- [ ] T5 Production (needs go-ahead): migrations, Contexto node, Decisor

## Acceptance criteria
- 10,000 GYD verified + "36,000 CUP each" for 2 cards -> nothing saved; reply states 36,000 CUP available, 72,000 asked.
- 15,000 GYD verified + 15,000 CUP x3 -> saved with FALTA: 9,000 CUP left to distribute or decide.
- 18,000 + 18,000 CUP on 10,000 GYD -> saved, complete.
- An operation without a verified deposit -> unchanged behavior.
- The Decisor never tells the bot a per-card GYD amount that contradicts the verified deposit.

## Progress / evidence
- 2026-11-07: root cause and map done (read-only; executions 668756, 666918, 666930; live md5 346793f8).
- 2026-11-07 T1 done, commit 28ae52d (not applied on staging yet; only rolled-back transactions). Staging and production
  `cerebro_guardar_reparto` were identical (md5 346793f8) before writing. Added `cerebro_reparto_disponible(op)` ->
  (base_gyd, tasa_cup, total_cup, tasa_usd, total_usd), all NULL while the deposit is not verified (status
  ready_to_transfer/transferring or cerebro_fondos_operacion.cubierto); guard in `cerebro_guardar_reparto` on the merged
  slots, compared in GYD, tolerance 1 CUP / 1 USD per card; numbers in replies are plain digits (no thousands separator).
  - RED (current live function, assertion reparto-within-deposit.sql): `ERROR: 14 expectation(s) failed` (cases 1a-1d,
    2b, 2c, 4b, 5a, 5b, 8b-8d, 9c, 10a); the unchanged-behavior cases (3, 6, 7, 8a, 9a, 9b) passed.
  - GREEN (BEGIN; 358; assertion; ROLLBACK): 33 `ok`, 0 FAIL, `ERROR: ALL PASS (rolled back on purpose)`;
    `staging-migracion.sh aplicar ... ` with DRY_ONLY=1: `dry-run OK`.
  - Rollback check (358 then ROLLBACK-358 in a rolled-back transaction): md5 346793f8 and ACL restored, helper gone.
  - relacionadas: `cerebro_guardar_reparto` pattern TOTAL 5 SAME 5 DIFF 0; wider pattern
    `registrar_reparto_multiple|cerebro_guardar_reparto|cerebro_guardar_beneficiario` TOTAL 28 SAME 28 DIFF 0 (7 of them
    already failed on the base for unrelated reasons: agreed-amount, deposit-anchor, grants-mirror-production,
    reparto-destino-node-adapters, saldo-model, visa-model, writers-resolver).

## Next step
T2 (context `reparto_cuadre`, using `cerebro_reparto_disponible`).
