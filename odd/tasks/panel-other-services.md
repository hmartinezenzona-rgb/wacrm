# Feature: the panel, the bot and the calculator handle the other services (recargas first)

## Objective
Every service the business sells — not only remesas — is collected by the bot, shown and handled in the chat's
Operations panel, and counted in the calculator.

## Problem (2026-10-03)
- The bot knows six services (cerebro_servicios: efectivo_usd, recargas, combos, mexico, visa, traduccion), and
  remittance_operations.service_type already allows remesa, combo, recarga, visa, traduccion, mexico (production: 585
  remesa, 22 recarga operations).
- The panel only lists service_type = 'remesa' (crm_operaciones_de_conversacion), so a recarga is invisible there.
- The calculator feed prices only remesas by delivery method; its CHECK already lists RECARGA, SALDO_MOVIL, DIRECTO,
  MLC, USDT (manual entries). Yosvany (54c25086, 6,200 GYD, a recarga per the owner) was closed manually as a remesa
  without beneficiary and never reached the calculator.

## Why
The owner closes these sales by hand today and they are missing from the panel and the profit numbers.

## Scope (authorized by the owner, 2026-10-03: "añadir los servicios que faltan al panel y que el bot los recabe")
Recargas first, end to end; then the other services one by one in the order the owner picks.

## Constraints
- Same discipline as remesas: staging first, owner check, production with go-ahead; DB migrations with self-reverting
  assertions; strict TDD (vitest); n8n changes by script with backups; panel copy English, icons over text.
- Don't break the remesa flow (cash, cards, Zelle, Clasica, Tropical).

## Tasks
- [x] S0 Explore recargas today: who creates the 22 recarga operations and with what data; the recargas service text the
      bot reads; how the manual calculator prices RECARGA / SALDO_MOVIL; what the bot does today when asked for one.
- [ ] S1 Owner decisions for recargas (one question at a time): data to collect (number(s) to recharge, plan/amount,
      operator), price and cost for the calculator, what "completed" means, the customer messages.
- [ ] S2 DB: the recarga's data on the operation (beneficiary row type 'recarga' or equivalent), the panel RPC lists
      non-remesa services, the calculator maps a recarga to RECARGA with its price/cost; Yosvany 54c25086 re-filed
      as a recarga and fed. Assertion first.
- [ ] S3 Bot (Cerebro): a tool to register the recarga data and the "what is missing" context, like efectivo_usd.
- [ ] S4 Panel: a recarga card (number, plan, amount) with the same actions (verify, complete with bell, close
      manually, delete).
- [ ] S5 Staging test with the owner, then production.
- [ ] S6.. Next services (combos, Mexico, visa, traduccion) in the owner's order, same steps.

## Acceptance criteria
A customer asks for a recarga in WhatsApp: the bot collects the data and opens the operation; the panel shows it with
its data; verifying, completing or closing it works like a remesa; the calculator shows its line with the right
profit.

## Checks
Strict TDD (vitest) for the app; self-reverting SQL assertions on staging and production; offline/parse checks and a
live staging test for n8n changes.

## Progress / evidence
- 2026-10-03: feature document created from the owner's request; nothing implemented yet. Starts after the cash work
  (odd/tasks/remesa-closing-and-cash.md, plan P1-P2, A8).
- S0 (2026-10-03, production read-only): 22 recarga operations (13-aug..2-oct), all with a legacy deal_id, no
  beneficiary except 2 (one cuban_card, one zelle — the 2-oct 83,200 GYD zelle one looks like a remesa misfiled), amounts
  mostly 6,200 GYD (also 1,000; 5,000; 12,400; 12,520; 14,400; 15,500). Creation today (deal-free, 160):
  cerebro_registrar_deposito files the deposit as service_type 'recarga' when the customer wrote "recarga", "etecsa" or
  "cubacel" in the last 24 h (and no card is pending) — words in an AUDIO do not count, which is likely why Yosvany's
  6,200 GYD became a remesa. Nothing stores the number to recharge; the panel lists only remesas; the calculator feed
  ignores recargas. Bot facts (cerebro_servicios 'recargas'): Etecsa promotions only; always the promotion's minimum;
  price by where the promotion starts — 500 CUP -> 5,200 GYD, 600 CUP -> 6,200 GYD; only the Cuban number is needed;
  done in 5-20 minutes; no discounts. The manual calculator prices RECARGA as facturado = units x saleGyd and invertido =
  units x costGyd x cupRate; production has no RECARGA line yet. Next: S1 owner decisions, first the cost of a recarga.
