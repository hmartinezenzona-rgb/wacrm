# Feature: special closed days (the bot answers as out of hours all day)

## Objective
On a day the business does not work (owner, 2026-10-03: Monday 2026-10-05, the anniversary) the bot answers all day as
out of hours, says why, and promises pending work for the next business day; before that day it already promises the
right next business day.

## Tasks
- [x] D1 DB `205_closed_days.sql` (+ ROLLBACK), commit 47a7a09: cerebro_config 'dias_cerrados' (JSON list of
      {"fecha","motivo"}, empty by default), cerebro_dia_cerrado, cerebro_proximo_dia_habil (skips Sundays and closed
      days), cerebro_cierre_especial_info(today) -> {hoy_motivo, proximo_habil, proximo_cierre}. Assertion
      closed-days.sql (closed day, next business day from Sat/Sun/Mon/Tue, what the bot reads on Mon/Sun/Sat/normal
      Tuesday, broken config closes nothing) RED -> GREEN on staging. Staging data: Monday 2026-10-05 "el aniversario de
      Remesas Ya".
- [x] D2 Cerebro staging gate101-dias-cerrados.py: 'Contexto conversacion' carries cierre_especial; 'Decisor': a closed
      day is out of hours all day (note carries the owner's sentence: "Hoy <dia> no estamos trabajando <motivo>; por aqui le atendemos igual y lo pendiente se hace <proximo_habil> a partir de las 9:00am."),
      the closing-soon and out-of-hours notes name the next business day and the closure when a closed day comes before
      it; 'Agente Remesas' verified-deposit line follows the same rule. Decisor parses; its schedule section run offline
      with a faked clock: Monday 12:00 -> closed all day, "se hace mañana martes 6"; Saturday 21:50 -> "OJO: el lunes 5
      no trabajamos ... abrimos el martes 6"; Saturday 16:45 closing soon -> "El siguiente dia habil es el martes 6 (el
      lunes 5 no trabajamos ...)"; normal Tuesday 11:00 -> open. Agent expressions parse; its line on Monday: "hoy no
      trabajamos por el aniversario de Remesas Ya, asi que su remesa se hace mañana martes 6, a partir de las 9:00am".
- [ ] D3 Owner check on staging, then production (205 + the Monday row in production's cerebro_config + gate101
      produccion) BEFORE Monday 2026-10-05.

## Notes
Adding another closed day later is a config change only: append {"fecha","motivo"} to cerebro_config 'dias_cerrados'.

Wording amendment (owner, 2026-10-03): the anniversary is the admin's and his wife's, so motivo is the clause
after "no estamos trabajando" ("porque estamos de aniversario"); default 'por un dia festivo'. 205 amended and
re-applied on staging (assertion ALL PASS); gate101 re-applied on staging with the owner's sentence, offline
simulation of Monday and of the Saturday-evening note OK.
