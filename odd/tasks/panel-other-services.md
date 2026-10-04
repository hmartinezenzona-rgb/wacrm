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
- S1 decisions so far (owner, 2026-10-03):
  - Sale price is fixed by the promotion's main balance the recipient gets: 500 CUP -> 5,200 GYD; 600 CUP -> 6,200 GYD
    ("la recarga siempre es así"; it changes very rarely).
  - Cost: the calculator guide's example "• Josefa 1 rec promo (23.1/6.2k/242)" = 23.1 USDT per recharge x 242 GYD per
    USDT -> invertido 5,590, facturado 6,200, retorno 610. The owner will confirm with the admin (Osmany) whether the
    500-CUP promotion costs the same. Proposal on the table: the cost per recharge (USDT) lives in the calculator rates
    (one place, like the cash rate), one value per promotion; the USDT rate is the calculator's usdt_buy_gyd; while a
    cost is missing the line is "pending" with that missing input, as the calculator already does for missing rates.
  - Several recharges in one deposit are normally DIFFERENT numbers, one per recharge (owner, 2026-10-03): the bot
    collects one Cuban number per recharge; the panel lists each number with its recharge.
  - Normally ONE promotion at a time (owner, 2026-10-03). Proposed: the current promotion (500 or 600 CUP, i.e. its
    price) is set in ONE place (the calculator rates, next to the cost); the bot quotes from it and counts recharges as
    deposit / price (12,400 at 6,200 -> 2 recharges, 2 numbers); with no promotion set the bot says there are no
    recharges now.
  - Completing a recharge sends the customer the "Listo" message AND the screenshot of the recharge (owner,
    2026-10-03): the same "Complete transfer" flow as remesas (screenshot per number, bell).
- S1 closed except the cost (admin). DESIGN for recargas (2026-10-03):
  - R1 DB: calculator_rate_versions gains recarga_precio_gyd (the current promotion's price, 5,200 or 6,200; NULL = no
    promotion) and recarga_costo_usdt (cost per recharge, USDT; NULL until the admin confirms) — set in the Calculator
    like the cash rate; crm_set_calculator_rates accepts both. Beneficiary type 'recarga' = one Cuban number per
    recharge; crm_beneficiarios_completos: every recarga row has a valid number and there are as many as recharges
    (deposit / price). The panel RPC lists recarga operations too. The calculator feeds a completed recarga as RECARGA:
    units = deposit / price, facturado = deposit, invertido = units x recarga_costo_usdt x usdt_buy_gyd; a missing cost
    leaves the line pending (recargaCostoUsdt). The A8 picker gains a Recarga icon (sets service_type recarga).
    Yosvany 54c25086 re-filed as a recarga and fed.
  - R2 Bot: the recargas service text quotes from recarga_precio_gyd (placeholders, like efectivo) and says there are
    no recharges when it is NULL; a tool registers the numbers; the context says how many numbers are still missing.
  - R3 Panel: a recarga card (Smartphone icon, "Recharge"), each number as a row with its copy chip; verify, complete
    (screenshot per number + bell), close manually, delete as for remesas. Calculator page: the two new rate fields.
  - R4 Notifier: the completed message for a recarga says "recarga" (not "remesa").
  - R5 Staging test with the owner, then production.
  - Known gap kept for later: a recarga asked by AUDIO is not detected (the keyword check reads typed text only).
- R1 DB part 1 (2026-10-03, staging): `198_recarga_model.sql` (+ ROLLBACK), commit 7833df9: calculator_rate_versions
  recarga_precio_gyd / recarga_costo_usdt (crm_set_calculator_rates accepts both), beneficiary type 'recarga',
  crm_beneficiarios_completos recharge rule (every row a valid Cuban mobile via cerebro_norm_celular_cu, as many as
  deposit / price; no price -> at least one; wrapped in coalesce(..., false)). Assertion recarga-model.sql (5 cases) RED
  ("unknown rate: recarga_costo_usdt") -> GREEN; cash/panel/calculator neighbours ALL PASS.
- R1 DB part 2 (2026-10-03, staging): `199_calculator_recarga.sql` (+ ROLLBACK), commit 98b9ade: RECARGA in
  calculator_service_for_operation / calculator_resolve_operation_service (service_type wins) / calculator_missing_rates
  (recargaPrecioGyd, recargaCostoUsdt, usdtBuyGyd) / calculator_feed_operation (units = floor(deposit / price), facturado
  = units x price, invertido = units x USDT cost x usdt_buy_gyd, currency REC, snapshot cup_rate = USDT rate, cost_gyd =
  USDT cost, sale_gyd = price). Assertion calculator-recarga.sql (Josefa's guide line 6200/5590.2/609.8 and its
  snapshot; 2 numbers = 2 units; missing cost -> pending recargaCostoUsdt; no numbers still RECARGA) RED -> GREEN;
  calculator-cash, feed-matrix, feed-from-beneficiaries, resolve-pending, calculator-entry-correction,
  manual-close-service, recarga-model, rate-versions ALL PASS.
  - financial-close.sql failed "totales ... 6": its fixture had been COMMITTED to staging at 17:25 UTC by my A6
    regression loop (that file is not self-reverting and I ran it with psql -1), and once more while diagnosing.
    Cleaned both times (7 ops 1001..1007 + "FC e*" entries, triggers disabled for the delete); now passes with a forced
    rollback and leaves 0 rows. Memory note added.
- DESIGN CHANGE (2026-10-03): the DB already holds the Etecsa promotions (promo_etecsa, detected automatically and
  confirmed by an admin; cerebro_promo_vigente) and the prices (precio_recarga: 500 -> 5,200, 600 -> 6,200), and the bot
  already quotes from them ("Ultima cotizacion"). recarga_precio_gyd would have duplicated them: 198/199 amended (not in
  production yet; staging rolled back 200-198 and re-applied). Now cerebro_recarga_precio(deposit) = the precio_recarga
  price the deposit is a whole multiple of (current promotion first), cerebro_recarga_unidades = deposit / price; the
  completeness rule and the calculator use them; a deposit matching no price (12,520) leaves the line pending with
  recargaPrecioGyd. Only recarga_costo_usdt stays as a calculator rate. Assertions updated (recarga-model 5 cases,
  calculator-recarga 5, panel-recarga 4) and GREEN; calculator-cash, manual-close-service, panel-closing-actions,
  feed-matrix, rate-versions ALL PASS. The app writer was told to drop the price field.
- R3 app (2026-10-03): commit 0f32bd4. Calculator field "Recarga: costo (USDT)" (recarga_costo_usdt; the price field was
  dropped with the design change); panel: a recharge card (Smartphone, "Recharge", "N recharges" from its recarga rows,
  numbers as copy chips, no remesa-only bits), the add control adds a number only on a recharge, the manual-close
  picker's sixth option "Recharge" (route accepts "recarga"); complete transfer already handles one proof per number.
  RED 7 + 14 -> GREEN; suite 1805; tsc, eslint clean.
- R2 DB (2026-10-03, staging): `201_recarga_numbers.sql` (+ ROLLBACK). crm_registrar_numeros_recarga(conv, text): Cuban
  mobiles in the text (pattern 8 digits starting 5/6, optional +53, separators between groups; cards and landlines are
  not matched) -> 'recarga' rows on the open recharge, no repeats, panel lock respected, audited
  (automation_recharge_numbers_registered), returns what is still missing (cerebro_recarga_unidades). Used by
  cerebro_registrar_deposito (a NEW recharge takes the numbers typed since asking) and cerebro_guardar_beneficiario_auto
  (a number alone with an open recharge). cerebro_registrar_deposito's body equals production's (checked before
  editing). Assertion recarga-numbers.sql (5 cases; the lock fixture is set as an admin — an automation write to the
  lock is suppressed by the guard) RED -> GREEN; cash-phone-not-a-card, partial-beneficiary-tools/-auto,
  deal-free-money-rules, deposit-path-without-deals, recharge and cross assertions ALL PASS.
- R4 notifier (2026-10-03, staging) via ~/cerebro-fase1/pruebas/gate94-notificador-recarga.py (after gate85/85b; first
  run restored from its backup and re-run to also say "Para poder hacer la recarga"): a recharge's verified line says
  "su recarga", a 'recarga' row is complete with its number, no rows asks for "el numero a recargar", completed says
  "Listo, su recarga ya fue realizada" (the Meta template fallback outside 24 h still says "remesa"). Offline run: 12
  cases, remesa/cash lines unchanged.
- R2 Cerebro (2026-10-03, staging) via gate95-cerebro-recarga.py: tool registrar_numeros_recarga (copy of the cash tool,
  same credential, wired as ai_tool) -> crm_registrar_numeros_recarga; one line in the agent's tool list (both copies of
  its instructions). Agent expressions parse.
- Staging test setup: a confirmed test promotion (600 CUP, today .. +3 days, huella staging-test-20261003) so the bot
  quotes recharges; the recharge cost left empty for the owner to set in the Calculator. App a43d66b deployed (BUILD_ID
  ilElZx0jGdwEuoxBNkqev, anterior d93815b; staging checks as usual). Test number reset.
- Owner test on staging (2026-10-03 21:26 UTC): "Para poner unas recargas / A dos números / 53821230 / 53456789 /
  Cuánto sería?" -> the bot quoted correctly ("600 CUP por 6,200 GYD cada una... sus dos números... 12,400 GYD") but
  nothing showed in the panel: 201 created the recharge only with the deposit, and 'Registrar beneficiario auto' kept
  one number in cerebro_beneficiario_parcial. The cost was not set yet.
- FIX `202_recarga_before_deposit.sql` (+ ROLLBACK), commit 5b87df0: cerebro_textos_cliente_recientes /
  cerebro_recarga_en_curso (the 160 rule, now shared); crm_registrar_numeros_recarga opens the recharge
  (collecting_information) when one was asked for; cerebro_guardar_beneficiario_auto opens/extends it with ALL numbers
  typed since asking; cerebro_registrar_deposito decides "recharge" up front, its movido search takes the open recharge,
  a moved deposit adds new numbers. Assertion recarga-before-deposit.sql (owner's exact messages -> one recharge with
  both numbers; deposit lands on it; the tool opens one; no recharge asked -> nothing) RED -> GREEN; recarga-numbers,
  deal-free-money-rules, deposit-path-without-deals, cash-phone-not-a-card, partial-beneficiary-tools/-auto, recharge,
  cross and cutover assertions ALL PASS. The owner's test conversation: its recharge opened with both numbers through
  crm_registrar_numeros_recarga (what the bot now does on the next number).
