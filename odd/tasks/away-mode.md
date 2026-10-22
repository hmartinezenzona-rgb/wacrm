# Away mode: temporary absence and closed days from the panel

## Objective

Let any admin tell the bot, in two clicks from any panel page, that the team stepped out ("tuvimos que salir un momento,
volvemos a las 15:00") or that a whole day is closed (anniversary, holiday). The bot keeps working exactly as always
(quotes, registers, answers) and adds one natural line with the reason and the return time.

## Problem and why

Owner, 2026-10-21, at the other admins' request: when they must leave, customers get no explanation; the 2026-10-05
anniversary closure had to be written into the database by hand. Migration 205 already gives the bot closed days with a
reason (whole days only, no panel UI). Mockup: https://claude.ai/artifact/Mupn2qd7d6BzKkDhFw4Pc9 (`Modo-Ausente.dc.html`).

## Decisions (owner)

- The bot does not stop: same behaviour as out of hours today, "agrega UNA sola linea ... y SIGUE ATENDIENDO NORMAL".
- Button in the global header (`src/components/layout/header.tsx`), active-absence banner under it (like
  `promo-banner.tsx`), closed-days list in Configuración.

## Scope

- In: migration 264 (absence in `cerebro_config`, read by `cerebro_cierre_especial_info`), admin API routes, header
  button + popover, global banner, Configuración section for closed days, Cerebro staging patch (Decisor note), staging
  test by the owner; production steps only with the owner's go-ahead each time.
- Out: changing what the bot does while absent; reminders (separate mockup); push notifications.

## Constraints

- Staging first; every production step (migration apply, panel publish, n8n write) needs its own go-ahead.
- `cerebro_config` has RLS and no policies: writes only through a service-role route guarded by `requireRole("admin")`.
- Guyana time (UTC-4, no DST). A broken or expired absence never changes the bot (fail open, like 205).
- TDD: strict (session CLAUDE.md "Strict TDD Mode: enabled"). Runners: `npx vitest run <files>` (panel),
  `infra/db/staging-migracion.sh aplicar ...` with a self-reverting assertion (SQL), n8n node tests under `pruebas/`.
- Never run the Cerebro n8n workflows. Push only to `privado`.

## Tasks

- [x] W1 Migration 264: `cerebro_config` key `ausencia` (`{"hasta": ISO timestamptz, "motivo": "porque ...", "por":
  name, "desde": ISO}` or empty), `cerebro_ausencia_actual(now)` (NULL when empty, broken or expired), and
  `cerebro_cierre_especial_info` gains key `ausencia` `{motivo, hasta, hasta_texto, por}` (null when none; other keys
  unchanged). Rollback + assertion; staging applied. Commit 65f4089.
  2026-10-21: RED observed (`function cerebro_ausencia_actual(unknown) does not exist`); staging `aplicar`: dry-run,
  apply, assertion OK, rollback OK (md5 equal to previous); `relacionadas`: closed-days SAME (ALL PASS), away-mode
  DIFF only because base lacks the function; `probar_migraciones.sh` all green. hasta_texto: "a las 3:00 pm",
  "mañana a las 9:00 am", "el martes 6 a las ..."; hasta normalized to UTC; non-object JSON -> NULL.
- [x] W2 API: `GET/PUT/DELETE /api/ausencia` (GET any member; PUT/DELETE admin) and `GET/PUT /api/dias-cerrados` (admin),
  service role, validation (future `hasta`, motivo length, dates), route tests.
  2026-10-22: RED 30/30 failing (modules missing); GREEN 46/46 (validate + both routes); tsc clean; full vitest
  224 files / 3101 tests passing. `hasta` > now + 1 min and <= 7 days; motivo 1..120 stored as typed; `por` from
  profiles.full_name (fallback "un admin"); broken dias_cerrados -> []; DB errors -> generic 500.
- [ ] W3 Panel: header button + popover (presets, return time, reason chips, bot preview) and global banner ("Ya
  volvimos"), hook with refetch on focus and every minute; i18n es/en; component tests.
- [ ] W4 Configuración: "Días cerrados" section (list, add, remove) using W2.
- [ ] W5 Cerebro staging: Decisor reads `cierre_especial.ausencia` and adds the note line; node test; applied to the
  staging Cerebro with backup (skill `wacrm-cerebro-n8n`).
- [ ] W6 Owner test on the local panel against staging; then production (migration, panel, n8n), each with go-ahead.

## Acceptance criteria

- An admin sets "back at 15:00, tuvimos que salir"; every member sees the banner; at 15:00 it disappears by itself.
- During the absence the bot answers as usual plus one line with the reason and the return time.
- Closed days are added and removed from Configuración; the bot behaves as with 205.
- A non-admin cannot set or clear an absence (403). Broken config never changes the bot.

## Progress

- 2026-10-21 created. RDD off (default). Next free migration 264 (checked branches and production).

## Next step

W1.
