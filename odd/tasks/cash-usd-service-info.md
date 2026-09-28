# Cash USD delivery in Cuba: the bot informs about it

## Objective
The bot knows the business now delivers physical USD cash in Cuba, informs about it with the real
terms, and hands the operation to a human. It never quotes cash at the Zelle/card USD rate.

## Problem / why
- New service reported by the user on 2026-09-28: physical USD cash delivered in Cuba (not Zelle,
  Clásica or Tropical). 290 GYD per USD, minimum 100 USD per delivery.
- User: "ponlo para que informe sobre ese servicio".
- Today the bot cannot offer it and would quote it wrong:
  - the `Agente Remesas` prompt says "Hay TRES [vías USD]": Zelle, Clásica, Tropical;
  - "Los cálculos en dólares valen igual para las tres vías": `calcular_usd` uses `tasas` usd = 260;
  - the service list and the keyword map in "## OTROS SERVICIOS", and the `consultar_servicio`
    `$fromAI` description, are hand-written lists.

## Scope
- DB: a row `efectivo_usd` in `cerebro_servicios`, activo, requiere_humano = true. Its `hechos` state
  ONLY the known facts: physical USD delivered in cash in Cuba; 290 GYD per 1 USD; minimum 100 USD per
  delivery (29,000 GYD); deposit by MMG as usual; an operator confirms the rest (delivery data, area,
  timing); no discounts. As a repo migration applied to staging, then prod.
- Prompt (staging, then prod):
  - VIA USD: cash is a 4th option when the customer says "usd/dólares"; cash has its OWN rate; NEVER
    `calcular_usd` / `calcular_usd_desde_gyd` for cash; call `consultar_servicio('efectivo_usd')`.
  - OTROS SERVICIOS: keywords 'efectivo', 'cash', 'dólares en mano', 'físico' →
    `consultar_servicio('efectivo_usd')`.
- `consultar_servicio` description: add `efectivo_usd`.

## Out of scope
- A full cash via: own rate in `tasas`, calculators, `marcar_destino_usd('efectivo')`, panel. It
  needs product answers first: does 290 change daily, which beneficiary data, which provinces.
- The single-source service catalog (see Next step).

## TDD
- Mode: strict (global user instructions).
- Runner: `~/cerebro-fase1/pruebas/evals/evaluar.py --workflow <id>` with new cases, plus a SQL check
  of `cerebro_servicio_get('efectivo_usd')`. RED on the current prompt first.

## Tasks
- [x] C1 — Eval cases (RED on current prod prompt):
  - "quiero mandar dólares" → the options include cash;
  - "¿entregan efectivo en Cuba?" → consultar_servicio('efectivo_usd'), 290, min 100 USD, operator
    offer;
  - "¿cuánto para 200 USD en efectivo?" → NO calcular_usd, NO 260 figure;
  - regression: "100 USD por Zelle" still → calcular_usd, 26,000 GYD.
- [x] C2 — Migration 137 (row) + ROLLBACK; applied on staging.
- [x] C3 — Prompt + tool description on staging `U52y1kSNvhgxvWeb` with a backup; evals GREEN, 0 DSML,
  existing order-beneficiary cases unchanged.
- [x] C4 — Production: migration on `hqztotshnlzaiziwjyzh`, Cerebro `jEzlVLCLUaJhVwzs` with a
  backup; read-back; watch.

## Acceptance criteria
- Asked about dollars, the bot mentions cash as an option. Asked about cash, it gives 290 and the
  100 USD minimum from the tool and offers an operator.
- It never quotes cash at 260 or computes it with the USD calculators.
- Zelle / Clásica / Tropical behavior unchanged.

## Progress
- 2026-09-28: document created after exploring the prod prompt and `cerebro_servicio_get`.
- 2026-09-28 C1 — RED confirmed against PROD `jEzlVLCLUaJhVwzs`: added
  `~/cerebro-fase1/pruebas/evals/casos/casos-efectivo-usd.json` (4 single-turn cases, following the
  `casos-conversaciones.json` format; `consultar_servicio`'s mocked result carries the planned
  `hechos` text via each case's `_resultados_grabados`, no new case-level harness support needed
  there). Found and fixed a real gap in `evaluar.py`'s single-turn harness first: `montar_workflow`
  built a temp workflow without a `Contexto conversacion` node, and the live `Agente Remesas`
  systemMessage references `$('Contexto conversacion')` directly (business hours) — every single-turn
  case against current prod/staging failed with HTTP 500 `NodeOperationError`/`nodeNotFound` before
  this fix, including pre-existing unrelated cases (verified with `casos-regresion.json`). Added the
  same `Contexto conversacion` code node `montar_workflow_multiturno` already had. After the fix:
  1/4 VERDE (the Zelle control case) — 3/4 ROJO as expected: no "efectivo" in the options, no
  `consultar_servicio` call for "¿entregan efectivo en Cuba?", `calcular_usd` called (rate 260) for
  "200 USD en efectivo". Report: `informes/informe-20260928-065153.json`.
- 2026-09-28 C2 — migration `137_cash_usd_service.sql` + `ROLLBACK-137-cash-usd-service.sql`
  (idempotent `INSERT ... ON CONFLICT (clave) DO UPDATE`). Confirmed `efectivo_usd` did not exist on
  staging first. Applied to staging (`kolppplawzdsjfydwejr`) with
  `docker run --rm -i --env-file .env.staging postgres:16-alpine sh -c 'psql "$CRM_STAGING_DATABASE_URL" -f -'`
  (same pattern as 115/136): `INSERT 0 1`. Verified with
  `SELECT * FROM cerebro_servicio_get('efectivo_usd')` via the same psql path (the Supabase MCP
  connection has no EXECUTE on that SECURITY DEFINER function — read-only there, as expected): one
  row, nombre "Entrega de dolares en efectivo en Cuba", hechos with 290/100 USD/29,000 GYD/MMG/sin
  descuentos, requiere_humano=true. Committed as `f5c3702`.
- 2026-09-28 C3 — staging Cerebro `U52y1kSNvhgxvWeb`: backup
  `~/cerebro-fase1/ROLLBACK-cerebro-staging-antes-efectivo-usd.json` (fresh GET, 117 nodes, staging
  prompt diff-verified identical to prod before editing). Edits (script
  `aplicar_efectivo_usd.py`, reused unmodified for the prod candidate): VIA USD ("Hay TRES" ->
  "Hay CUATRO", 4th bullet EFECTIVO with consultar_servicio('efectivo_usd'), never
  calcular_usd/calcular_usd_desde_gyd; "El deposito NO cambia... tres" -> "...cuatro"; clarified
  "Los calculos... para las tres vias" -> "para Zelle, Clasica y Tropical (NO para efectivo)");
  OTROS SERVICIOS (added "entrega de dolares en efectivo en Cuba" to the list and the keyword line
  'efectivo'/'cash'/'dolares en mano'/'fisico' -> consultar_servicio('efectivo_usd')); the
  consultar_servicio $fromAI description now lists efectivo_usd. Pre-flight (assert in script): node
  count unchanged (117), only `Agente Remesas` and `consultar_servicio` differ, `disabled` flags and
  `connections` byte-identical before/after. PUT, then GET read-back confirmed the exact same 2 nodes
  differ, 117 nodes, edits present verbatim.
  - GREEN: `casos-efectivo-usd.json` against staging — 4/4 VERDE, 0 DSML, 0 errors. Report:
    `informes/informe-20260928-065503.json`.
  - Regression: `casos-orden-beneficiario.json` (13 multi-turn cases, unscored/observational format)
    against staging — 0 DSML, 0 `reasoning_content`, 0 execution errors across all 12 counted cases
    (1 dropped per B2). Report: `informes/informe-20260928-070540.json`, compared programmatically
    against the B1 baseline (`informe-20260928-061342.json`): the 5 Zelle-family cases (the ones this
    feature could affect, via VIA USD) match the baseline's tool-call pattern turn by turn exactly,
    including `registrar_beneficiario_zelle` with the correct name/account. Two CUP-only
    `orden-beneficiario-tarjeta` cases (`tarjeta-luego-celular`, `tarjeta-con-espacios-o-guiones`)
    picked a different calculator (`calcular_inverso` vs `calcular_envio`) than the baseline run;
    that family carries no `esperado` (out of scope since B3, model-variance only, unrelated to VIA
    USD/OTROS SERVICIOS — CUP-only messages, no USD or efectivo wording) and the baseline itself
    already showed variance on one of the two (`tarjeta-luego-celular` called both tools in the
    baseline run).
  - Production candidate prepared, NOT applied: `~/cerebro-fase1/candidato-cerebro-PRODUCCION-efectivo-usd.json`,
    built from a fresh GET of prod `jEzlVLCLUaJhVwzs` (116 nodes) with the same script/edits. Diff
    summary: only `Agente Remesas` and `consultar_servicio` differ (same 2 nodes as staging); node
    count 116 -> 116; `active` unchanged (true); `disabled` flags and `connections` byte-identical
    (asserted in-script). Not PUT anywhere.

- 2026-09-28 parent review before C4:
  - The 2 card-case differences are not a regression. "Necesito mandar 60 mil CUP" is correctly
    `calcular_inverso` (21,430 GYD), where the baseline had used `calcular_envio`.
  - Fixed one leftover contradiction on staging and in the prod candidate: "a cual de las tres vias
    quiere que llegue" became "a cual de las cuatro vias quiere que llegue (Zelle, Clasica, Tropical
    o efectivo)". Staging re-run 4/4 GREEN (`informe-20260928-070956.json`).
- 2026-09-28 C4 — production:
  - Migration 137 applied on `hqztotshnlzaiziwjyzh` (MCP). `cerebro_servicio_get('efectivo_usd')`
    returns the row, requiere_humano = true.
  - Cerebro `jEzlVLCLUaJhVwzs` updated. Backup:
    `~/cerebro-fase1/ROLLBACK-cerebro-PRODUCCION-antes-efectivo-usd.json`.
  - Pre-flight: only `Agente Remesas` and `consultar_servicio` differ; connections and `disabled`
    flags identical. Read-back equals the candidate; the workflow is active.
  - Evals against the prod prompt: 4/4 GREEN (`informe-20260928-071139.json`).
    - Dollars: the options include cash.
    - Cash question: 290, 100 USD minimum, 29,000 GYD.
    - 200 USD cash: 58,000 GYD with no `calcular_usd`.
    - Zelle 100 USD: 26,000 GYD.
  - Notes:
    - For 200 USD the model multiplied 200 x 290 itself (correct, but not from a tool). A cash
      calculator belongs to the full cash via (out of scope).
    - "Deposit by MMG" and "no discounts" in `hechos` follow the other services' policy. They were not
      stated by the user for cash; the user was told.

- 2026-09-28 migration 139, applied on staging (psql) and prod (MCP). The user confirmed the facts:
  the business always receives by MMG, no discounts. Cash delivery needs 3 recipient data: phone, a
  photo of the ID card (carnet) and address. `hechos` now lists them; requiere_humano stays true.
  Still unknown for the full via: does 290 change daily, which provinces.

## Next step
Watch real cash questions; the full cash via awaits product answers.
