# Contact avatars: match the name's gender, never repeat

## Objective

The illustrated customer avatars (DiceBear notionists, live since 2026-10-21, f7ebf9c) look like the customer's
name (feminine features for feminine names, masculine for masculine) and no two customers share the same visible
avatar.

## Problem and why

- Owner, 2026-10-21: saw feminine avatars on masculine names and vice versa, and repeated avatars.
- Today the avatar is a pure hash of the contact id: it ignores the name and two contacts can land on the same hair
  and background (64 hairs x 5 backgrounds, 246 contacts in production).

## Design

- Hair pools (classified by eye from a rendered sheet of the 64 notionists hairs, 2026-10-21):
  - feminine (24): variant02 04 08 10 11 23 24 28 29 36 37 39 41 43 45 46 47 48 57 58 59 61 62 63
  - masculine (33): variant01 03 05 06 07 09 12 13 15 16 17 18 19 21 22 25 26 27 31 33 34 35 38 44 49 50 51 52 53
    54 55 56 60
  - neutral (7): variant14 20 30 32 40 42 hat
  - beard only for masculine.
- DB (migration 263): `contacts.avatar_gender` ('f'|'m'|'n') inferred from the first name by `crm_avatar_genero(text)`
  (common-name dictionary incl. Cuban names, then suffix rules, else 'n'); `contacts.avatar_seq` = 1-based order of
  the contact inside its gender group (per-gender counter, advisory lock, backfill by created_at). A name change
  only reassigns when the stored gender was 'n' and the new name gives 'f' or 'm'.
- App: avatar index k = avatar_seq - 1 -> hair = pool[k mod H], background = palette[(k div H) mod 8]; eyes, brows,
  lips, glasses (and beard for 'm') from the contact-id hash. Distinct hair+background up to 192 f / 264 m / 56 n.
  Without the columns (old rows / missing data) it falls back to today's hash.

## Constraints

- Staging first; owner go-ahead for the production migration and the panel publish (separately).
- Strict TDD (SQL assertion for the migration; vitest for the app). Lockfile regenerated with node:20 npm if deps change.

## Tasks

- [x] A1 Migration 263 (columns, `crm_avatar_genero`, per-gender seq trigger, backfill) + ROLLBACK + assertion; staging.
- [x] A2 App: pools + mapping + ContactAvatar uses avatar_gender/avatar_seq; queries expose the columns; tests.
- [x] A3 Staging deploy, owner check; production migration then panel (separate go-aheads).

## Acceptance criteria

- No two contacts of the same gender group share hair+background while the group is under its capacity.
- Feminine names never get beards or masculine hairs; unknown names get neutral hairs.

## Progress

- 2026-10-21 created. Production: 246 contacts, none with a photo, 16 names without letters.

- 2026-10-21 A1 92ed9d9 (migration 263; assertion RED then GREEN; staging cycle OK, rollback md5-equal). Rules widened
  after a read-only production estimate (first pass: 78 neutral of 246; after: f 113, m 104, n 29).
- 2026-10-21 A2 31309a3 (writer, TDD): pools, mapping, gender/seq props at the 4 call sites; vitest 3036, tsc clean.
- 2026-10-21 A3: staging 31309a3 (BUILD_ID Upf9N8tDPlSc3MHhNd4PR). Owner go-ahead ("sí, aplica la migración y publica
  el panel"): 263 in production 22:38Z (20261021223821), verificar 2/2; backfill f 113 / m 104 / n 29, 0 missing,
  0 repeated. Panel release/prod-avatars-gender 233cfec (served f7ebf9c + 31309a3), BUILD_ID go9tKHYf_XbPCAjQ-9CCp,
  rollback f7ebf9c.

## Next step

Done. If a group nears its capacity (192 f / 264 m / 56 n), add backgrounds to the palette.
