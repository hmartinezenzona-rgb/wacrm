# Service catalog from one place (cerebro_servicios)

## Objective
The list of services the bot offers comes from `cerebro_servicios` only. Adding, editing or
switching off a service is one row, with no prompt or workflow edit. The bot never offers a service
that is not active, and never ignores one that is.

## Problem / why
- User, 2026-09-28: service info must be "fácil de editar en un solo lugar", so the bot does not
  invent anything or, worse, fail to mention a service the business does offer. RAG does not apply:
  6 services, ~4 KB of text. The user chose option 1 ("sí, haz lo de la opción 1").
- Today the details are already single-source (`consultar_servicio` → `cerebro_servicio_get` reads
  the table live). But WHICH services exist is hand-written in 3 places:
  - `Agente Remesas` prompt, "## OTROS SERVICIOS": the list plus a keyword → key map;
  - `consultar_servicio` `$fromAI` description: an enumeration of keys;
  - "## VIA USD": "Hay TRES vías" (the trigger: cash USD would have been denied, see
    cash-usd-service-info.md).

## Approach (option 1)
- `cerebro_servicios` gains `palabras_clave text[]` and `resumen text` (one line).
- A DB function returns the compact catalog of ACTIVE services (clave, nombre, resumen,
  palabras_clave). The Cerebro injects it into the per-turn context, the same pattern as
  "Datos del negocio" and `cerebro_horario()`.
- The prompt keeps only the RULES: the catalog is in the context; details, prices and conditions
  only from `consultar_servicio(clave)`; a service not in the catalog does not exist, so offer an
  operator. No hand-written lists or key enumerations.
- The `consultar_servicio` description refers to "a clave from the catalog", with no enumeration.
- Figures the bot CALCULATES stay in numeric fields / `tasas`, never only in text.

## Scope
- One migration (columns, backfill of the 6+ rows, catalog function) + rollback.
- Cerebro: the context node + prompt + tool description. Staging first, then production with a
  backup.

## Out of scope
- A panel page to edit services (offered to the user as a complement; not requested yet).
- The Decisor's special cases (e.g. MLC) unless they list services by hand. Map them and report.
- The 3 USD vias' instructions (Zelle / Clásica / Tropical): they are delivery ways of remittances,
  not catalog services. Their text stays in the prompt.

## Constraints
- Starts after cash-usd-service-info (C1–C4): same prompt and workflow.
- Token budget: the catalog block must stay small (target < 400 tokens for ~7 services).

## TDD
- Mode: strict (global user instructions).
- Runners: `evaluar.py --workflow <id>` cases; SQL assertions on staging in a rolled-back
  transaction.
- Key RED case: a new service row inserted only in the DB (in the harness mock) is NOT offered by
  the current prompt; after the change it is, with zero prompt edits.

## Tasks
- [ ] S1 — Map every place that lists services by hand (prompt, tools, Decisor, other nodes); record.
- [ ] S2 — Evals RED: a service that exists only in the table; a switched-off service is not
  offered; the existing service cases (combos, recargas, visa, traduccion, mexico, efectivo_usd)
  stay correct.
- [ ] S3 — Migration 138: columns + backfill + catalog function; SQL assertions; applied to staging.
- [ ] S4 — Staging Cerebro: inject the catalog, remove the hand-written lists; evals GREEN; the
  order-beneficiary and cash regressions unchanged; 0 DSML.
- [ ] S5 — Production with a backup; read-back; watch; record how to add a service (one-row SQL).

## Acceptance criteria
- Adding a service = one INSERT; switching one off = `activo = false`. The bot follows both with no
  other change.
- No regressions in the existing service and USD cases.

## Progress
- 2026-09-28: document created. Waiting for cash-usd-service-info to finish.

## Next step
S1, after C4 of cash-usd-service-info.
