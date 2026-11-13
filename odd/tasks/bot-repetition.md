# Feature: the bot stops repeating the hours line and the pending data request

## Objective
The out-of-hours line is said once per conversation per day, and a pending data request is not re-asked when the
customer only acknowledges ("ok", "gracias", "en un momento") or talks about something else shortly after the last ask.

## Problem / why (audit 2026-10-30..11-13, production, read-only)
- Out-of-hours line ("Estamos fuera de horario..." / "se procesa a partir de las 9:00am"): 128 of 201 off-hours bot
  messages carry it; 86 are repeats in the same conversation (42 conversations), 51 less than 1 h after the previous one.
  Production Decisor (pruebas/decisor/produccion/decisor.jscode) "FUERA DE HORARIO" notes (~lines 652-654) are stateless
  and LINEA_HORARIO_OBLIGATORIA (~line 638) forces it on every deposit-related turn; the away notice (~679-683) already
  has a "YA AVISADA HOY" guard, the hours line has none. In retained executions 7 of 12 follow-up turns repeated it
  (e.g. 721014, 721302, 722294).
- Re-asks: 33 unjustified repeats of the same pending item within 6 h in 23 of 94 conversations (26 after unrelated talk,
  3 after a bare ok/gracias, 4 of data already saved); "¿Me pasa los datos de quien recibe?" repeated verbatim 13 times;
  27 of 49 repeats less than 5 min after the previous ask (execs 707240/707558 conv 9ea48754: "Ok"/"Aa ok" answered with
  another ask). Assumed root: the BREVEDAD follow-up note (~line 556) "Pide SOLO el dato que falta" on every follow-up turn;
  esperaTercero is the only stop condition.
- The 49 identical hold messages (conv c791477d, 2026-11-09) were the abuse-limit case already fixed by 361/363
  (bloquear_ahora / derivar_ahora only on the first block, atomic); 0 repeats in the 30 days since. No work here.

## Owner decisions
- 2026-11-13: "si" to: hours line once per day per conversation; no re-ask after an ack or unrelated message (at most
  once per period); then the pre-send freshness check (separate feature).

## Scope
In: production-lineage Decisor (pruebas/decisor/produccion/decisor.jscode, produccion/correr.ts pin,
decisor-produccion.test.ts); staging is not usable for this lineage (staging runs the other session's Decisor), so it
ships to production after tests with the owner's go-ahead (backup, publicar-decisor --esperado <live md5>).
Out: the other session's Decisor and its brevity work (pruebas/decisor/decisor.jscode, odd/tasks/bot-brevedad.md);
prompt; SQL unless a context field is missing (then a migration with assertions).

## Constraints
- Strict TDD with vitest (`npx vitest run pruebas/decisor/produccion`), RED then GREEN, real shapes as fixtures (no customer
  data).
- The "already said today" and "last ask" facts must come from data the Decisor already receives (history / context); if a
  field is missing, add it in SQL (Contexto conversacion) rather than guessing.
- Never touch pruebas/decisor/decisor.jscode, pruebas/decisor/correr.ts, pruebas/decisor/decisor-notas.test.ts,
  odd/tasks/bot-brevedad.md. No AI attribution in commits. RDD off.

## Tasks
- [ ] T1 Hours line once per day: the FUERA DE HORARIO note and LINEA_HORARIO_OBLIGATORIA fire only when no bot message of
      this conversation today (Guyana day) already carried the line; tests (first turn says it, follow-up does not,
      next day says it again, deposit turn after it was said does not repeat it)
- [ ] T2 No re-ask: the follow-up "pide el dato que falta" is suppressed when the customer's batch is only an ack
      (ok, gracias, dale, en un momento, ahorita, aa ok...) or does not touch the pending item and the same item was asked
      less than N minutes ago (default 30, from history); tests (9ea48754 shape, unrelated question, real new data still
      asked/confirmed)
- [ ] T3 Production (needs go-ahead): backup, publish, first executions check

## Acceptance criteria
- A conversation off hours hears the hours line once that day.
- "Ok" after "¿Me pasa la tarjeta?" gets no new ask within 30 min.
- Data requests still happen when the customer moves the send forward; existing tests stay green.

## Progress / evidence
- 2026-11-13: audit (counts above); hold-message fan-out verified fixed (cerebro_control_abuso/bucle atomic; 30-day history
  only the 2026-11-09 incident).

## Next step
T1.
