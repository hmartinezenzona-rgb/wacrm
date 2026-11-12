# Feature: the agreed amount follows the latest quote, and a reparto collapsed to one card leaves no empty recipient

## Objective
When the bot re-quotes a send (new amount), the deposit check uses the new amount, never an older quote; when the
customer collapses a multi-card reparto into one card, the operation keeps one recipient and never asks for the data of
a person that no longer exists.

## Problem / why (2026-11-12, conversation 29597f4b, operation af44d909)
- 12:40 UTC the bot quoted "Por *5,000 GYD* llegan *18,000 CUP*" -> cerebro_cotizacion gyd 5000 (trigger
  trg_registrar_cotizacion -> cerebro_monto_cotizado).
- 15:09 the bot re-quoted "Con *10,000 GYD* salen *36,000 CUP*: *18,000 CUP* para cada tarjeta" and 15:23 "los
  *10,000 GYD* quedan completos ... *36,000 CUP*". cerebro_monto_cotizado recognizes only "depositar *X gyd*" and
  "por *X gyd* (le )llegan *", and its exclusion regex `a cada` also matches "par**a cada**", so neither re-quote was
  recorded; the 5000 quote stayed vigente (6 h window, no closed op since).
- 15:21 a 10,000 GYD deposit -> cerebro_objetivo_minimo set objetivo 5000 (pedido 'cotizacion') -> the bot told the
  customer "mandó 5,000 GYD más de lo que habíamos hablado" (false) and the operation went to incident; an admin forced
  verification (15:47) and closed it manually (15:56).
- 15:09 tool registrar_reparto_multiple (exec 708472) wrote 2 recipients x 18000 (block 2). 15:16 the customer said
  "todo en la misma tarjeta": exec 708528 called the tool with only person 1 = 36000 CUP -> block 3 kept a person 2
  (18000, no card) carried from block 2; the model then called again with person 2 = "0 CUP" -> block 4 vigente has
  position 2 with amount 0, no card, no phone. At 15:47 the verified-deposit notice asked "nos falta la tarjeta y el
  celular". Writer: cerebro_guardar_reparto (tool name logged as registrar_reparto_multiple), latest repo definition in
  337/359.

## Owner decisions
- 2026-11-12: fix at root ("si, arréglalo de raíz").

## Scope
In: SQL migration 366 (+ ROLLBACK, staging assertions); staging; production with go-ahead.
Out: Decisor (no change needed), panel, n8n nodes.

## Constraints
- Strict TDD: SQL assertions in rolled-back transactions; RED observed before GREEN. Real case shape as fixture (ids and
  amounts only, no customer data).
- Read LIVE production bodies first and confirm they match the repo before redefining.
- Staging first (`infra/db/staging-migracion.sh`); production only with the owner's explicit go-ahead.
- Never touch pruebas/decisor/decisor.jscode, pruebas/decisor/correr.ts, pruebas/decisor/decisor-notas.test.ts,
  odd/tasks/bot-brevedad.md. No AI attribution in commits. RDD off.

## Tasks
- [x] T1 Quote parser: cerebro_monto_cotizado records the bot's re-quote phrasings ("con *X GYD* (le )salen/llegan *",
      "los *X GYD* quedan ... *Y*"); the per-card exclusion matches only the minimum/per-card notices, not "para cada";
      assertions with the 15:09 and 15:23 texts (-> 10000) and existing negatives unchanged
- [x] T2 Reparto collapse: a reparto call with one person writes one recipient (no carry-over of a previous person 2);
      a person with amount 0 and no card/phone is never written as a recipient; assertions (block shapes above)
- [x] T3 Staging: apply 366, related assertions (`relacionadas`)
- [ ] T4 Production (needs go-ahead)

## Acceptance criteria
- Quote 5,000 then re-quote 10,000 -> deposit 10,000 is not an excess; objetivo 10,000.
- Two cards then "todo en la misma tarjeta" -> one vigente recipient with the full amount; no request for a second
  card/phone.
- Existing quote and reparto assertions stay green.

## Progress / evidence
- 2026-11-12: root cause (read-only production: cerebro_cotizacion row, tool_execution_log execs 708472/708528,
  remittance_beneficiaries blocks 1-5 of af44d909, remittance_admin_audit).

- 2026-11-12 T1 (commit 8d69756): migration 366 part A, assertion supabase/staging/assertions/stale-quote-requote.sql.
  RED (staging, no 366): `p2: "Con X GYD salen" re-quote, got <NULL>`. GREEN (with 366): `PASS parser`, `PASS negatives
  unchanged`, `PASS trigger: quote follows the latest re-quote`, `ALL PASS`. Exclusion `a cada` became `\ma cada`
  (per-card share notices keep excluding; "para cada tarjeta" no longer does); "a esa tarjeta" does not match "en esa misma
  tarjeta", checked by the p3 case. Live production bodies read read-only before redefining: equal to the repo (171).
- 2026-11-12 T2 (commit f5613bc): migration 366 part B, assertion supabase/staging/assertions/reparto-collapse.sql.
  RED: `case 1: one recipient expected, got 1=...:36000CUP | 2=_:_:18000CUP`. GREEN: PASS 1, 2, 3, 3b, 3c, 4, 5, 6, `ALL PASS`.
  Design: carry-over by position is kept (tool contract: "lo que mandas se suma a lo guardado"); only a call naming ONE person
  whose CUP amount raises its own and is >= the sum of all saved amounts drops the other persons; a person with amount 0/none and
  no card/phone is never written.
- 2026-11-12 T3: `staging-migracion.sh aplicar ... reparto-collapse.sql ... cerebro_monto_cotizado,cerebro_guardar_reparto`:
  dry-run OK, apply OK, assertion OK, rollback OK (md5 equal to previous); ACLs preserved. `relacionadas` (reparto, quote and
  cotizacion assertions): TOTAL 24, SAME 23, DIFF 1 (stale-quote-requote, the new RED->GREEN assertion; expected). The SAME ones
  that fail on both sides fail for pre-existing reasons (missing pg_temp helpers or staging state), identical on base.

## Next step
T4 (production, needs the owner's go-ahead).
