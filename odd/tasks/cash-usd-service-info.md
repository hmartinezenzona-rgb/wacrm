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
- [ ] C1 — Eval cases (RED on current prod prompt):
  - "quiero mandar dólares" → the options include cash;
  - "¿entregan efectivo en Cuba?" → consultar_servicio('efectivo_usd'), 290, min 100 USD, operator
    offer;
  - "¿cuánto para 200 USD en efectivo?" → NO calcular_usd, NO 260 figure;
  - regression: "100 USD por Zelle" still → calcular_usd, 26,000 GYD.
- [ ] C2 — Migration 137 (row) + ROLLBACK; applied on staging.
- [ ] C3 — Prompt + tool description on staging `U52y1kSNvhgxvWeb` with a backup; evals GREEN, 0 DSML,
  existing order-beneficiary cases unchanged.
- [ ] C4 — Production: migration on `hqztotshnlzaiziwjyzh`, Cerebro `jEzlVLCLUaJhVwzs` with a
  backup; read-back; watch.

## Acceptance criteria
- Asked about dollars, the bot mentions cash as an option. Asked about cash, it gives 290 and the
  100 USD minimum from the tool and offers an operator.
- It never quotes cash at 260 or computes it with the USD calculators.
- Zelle / Clásica / Tropical behavior unchanged.

## Progress
- 2026-09-28: document created after exploring the prod prompt and `cerebro_servicio_get`.

## Next step
C1.
