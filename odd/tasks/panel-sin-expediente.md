# Panel without the funding case (expediente)

Status: IN PROGRESS (2026-10-27)

## Objective

Remove the funding-case (expediente) UI from the WaCRM panel while keeping every
Hermes improvement and the rest of the current interface. The database objects
stay in place, dormant; the restored Oct-21 Cerebro and the current panel both
continue to work.

## Problem

The owner asked to restore the bot to its 2026-10-21 behaviour and to take the
expediente out of the panel. Deploying the pre-expediente build (`c18b2815`)
would also drop 24 Hermes commits made after that build, so the panel is edited
instead of rolled back.

## Scope

In scope:
- Delete the funding-case block and its test.
- Delete the four `/api/funding-case` routes.
- Delete `src/lib/funding-case/types.ts`.
- Remove the block from `contact-sidebar.tsx`.
- Remove the `Inbox.fundingCase` message block from `messages/en.json` and
  `messages/es.json`.

Out of scope:
- Migrations 326-334 and their database functions (kept dormant).
- Hermes code and every other panel surface.

## Tasks

- [ ] T1 Remove the funding-case block, routes, types, sidebar hookup and i18n keys.
- [ ] T2 Run the panel checks (vitest + tsc) and confirm nothing else imports it.
- [ ] T3 Commit the removal as one work unit.
- [ ] T4 Build and publish the panel; record BUILD_ID and rollback sha.

## Acceptance criteria

- No panel source imports `funding-case`.
- The inbox sidebar renders without the funding-case block.
- The published BUILD_ID serves the removal and the previous build remains as rollback.

## Checks

- `npx vitest run` for the affected component suites.
- `npx tsc --noEmit`.
- Published panel reports the new BUILD_ID and the previous one as rollback.
