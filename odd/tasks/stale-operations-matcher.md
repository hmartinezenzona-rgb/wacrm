# Old open remesas must not steal a new remesa's beneficiary

## Objective
When a customer reuses a Zelle account for a new remesa while an old one is still open, the data
goes to the NEW remesa, and the team is told about old remesas left open.

## Problem / why
Follow-up point 2 of the beneficiary work. The user chose option B on 2026-09-28: attack the real
cause instead of making the bot ask.

All 5 "operacion_ambigua" handoffs since August came from old remesas left open, not from real
"which person?" cases. They happened with the old resolver.

Replaying them (as they were at the handoff moment) through the CURRENT matcher (126), with
`pruebas/replay-derivaciones-ambiguas.py`, gives 3 right and 2 WRONG, both on the old remesa:
- **1727ef31 (JOSE SAO):** the same account was used on 19-Sep (125 USD) and on 26-Sep (200 USD).
  The matcher anchors on the FIRST message with the account, finds "125 zelle" next to it and picks
  the paid 19-Sep remesa. The right one is the 26-Sep remesa.
- **de846b30 (DTZ):** the same account was sent on 14-Sep and 18-Sep. Proximity to the FIRST
  occurrence picks the 14-Sep remesa, so the new one stays without a beneficiary.

## Scope
- Migration 133: `cerebro_resolver_operacion_beneficiario` anchors on the MOST RECENT customer
  message that contains the account, not the first. Nothing else changes.
- Daily alert to the team listing remesas open for more than 48 h (channel still to be confirmed
  from the existing alert infrastructure).

## TDD
- Mode: strict, from the global config.
- Runners:
  - `supabase/staging/assertions/beneficiary-matcher.sql` on ensayo, then staging;
  - `pruebas/replay-derivaciones-ambiguas.py` (the 5 real cases).

## Tasks
- [x] S1 — Migration 133: anchor on the latest occurrence.
  - Assertion cases 8 (reused account with an amount, 1727ef31) and 9 (reused account without an
    amount, de846b30): RED, then GREEN.
  - Cases 1–7 stay green.
  - The replay gives 5/5 on the new remesa.
  - Apply on ensayo, staging and prod.
- [x] S2 — Daily alert of old open remesas to the team.

## Acceptance
- 1727ef31 → the 26-Sep remesa; de846b30 → the 18-Sep remesa. The other 3 stay on the new remesa.
- The existing matcher cases (amount, proximity, reparto, other beneficiary, rule C, no evidence,
  single) are unchanged.

## Progress
- 2026-09-28 S1 — migration 133.
  - Assertion cases 8–9: RED (case 8 picked the old remesa by amount), then GREEN 9/9; cases 1–7
    unchanged.
  - Replay of the 5 real handoffs: 5/5 on the new remesa (3/5 before).
  - The rollback restores the exact prod body (md5 7504b99e); checked.
  - Applied on staging (9/9) and prod; the md5 is the same on both (60cbe40c…). Commit 3888b37.
- 2026-09-28 n8n incident: the server stopped answering at 03:05Z (healthz timeouts; internet
  fine). The user fixed a network problem.
  - After the fix: healthz answers in 0.3 s and the 4 workflows are active.
  - No customer message arrived during the outage.
- 2026-09-28 S2 — migration 134.
  - Changes:
    - `notifications_type_check` gains `remesa_abierta_vieja`;
    - new `cerebro_avisar_remesas_abiertas_viejas(p_horas, p_ignorar_horario)`.
  - Behaviour:
    - one panel notification per account member;
    - at most once a day (cerebro_alertas);
    - from 09:00 Guyana time, not on Sundays;
    - settings: remesas_viejas_horas / _repetir_min / _desde.
  - Assertion `stale-operations-alert.sql`: RED (function missing), then GREEN 4/4.
    - Test fix: completing a remesa needs the panel origin; automation completions are suppressed
      by the guard.
  - The rollback drops the function; checked.
  - The panel renders any notification type (default icon), so no frontend change was needed.
  - Dry run in prod: 1 remesa listed (Librada, 4 days, Solicitada, no deposit).
  - Applied on staging (4/4) and prod; the md5 is the same on both (2825c776…). Commit fba28e1.
  - n8n workflow "Vigilante - remesas abiertas viejas" 4ptJpwWnjkyiAjvc runs every hour and is
    active. Its call returns 0/0 outside hours.
