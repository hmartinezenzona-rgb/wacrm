# ci-green-and-dependencies

**Objective**: make CI's four steps green (lint, typecheck, test, build) and remove the critical Next.js advisory without changing app behavior.

**Starting state (audit 2026-11-22)**: `npm run lint` exited 1 with 3 errors; `next@16.2.6` carried the critical advisory cluster; `npm audit` reported 2 critical / 15 high.

**Changes**
- `src/lib/storage/use-media-src.ts`: replaced the synchronous `setSrc(null)` in the effect with state that stores the input alongside the resolved URL and derives `null` while a new URL resolves. Same behavior, no cascading render.
- `src/app/(dashboard)/notifications/page.tsx`: documented `eslint-disable-next-line react-hooks/set-state-in-effect` on `load()`; it only sets state after awaiting the query, which the compiler cannot follow.
- `src/hooks/use-ausencia.test.tsx`: the test harness now captures the hook result inside an effect instead of reassigning a module-scope variable.
- Dependencies: `next` 16.2.6 → **16.4.6** (exact) clears the critical cluster; `shadcn` → **^4.23.0** (its high advisory is gone and `shadcn/tailwind.css` still resolves); `@modelcontextprotocol/sdk` **^1.32.2** and `zod` **^4.6.7** declared explicitly — both were imported directly but undeclared (the SDK arrived transitively through `shadcn` and disappeared when it was removed).
- `npm audit fix` (no `--force`) cleared the remaining high advisories.
- `eslint-plugin-react-hooks` pinned to **7.0.1** (exact) and `eslint-config-next` pinned to **16.2.6** (exact). Plugin 7.1.1 adds 41 errors across 4 rules over pre-existing code; upgrading it is a separate refactor.

**Result**
- lint: 0 errors (52 warnings).
- typecheck: exit 0.
- tests: 305 files, 4224 passed.
- build (`next build`, Turbopack) with CI env vars: exit 0.
- `npm audit`: 0 critical, 0 high, 5 moderate (`@dicebear/core`, `@ts-morph/common`, `minimatch`, `shadcn`, `ts-morph`).

**Notes**
- Turbopack cached the resolution failure from the first failed build; clearing `.next` was required after restoring `shadcn`.
- The build warns that the `middleware` file convention is deprecated in favor of `proxy`. Follow-up: migrate `src/middleware.ts`.
- Follow-up: upgrade `eslint-plugin-react-hooks` to 7.1.1 and fix the 41 violations (32 `set-state-in-effect`, 5 `immutability`, 2 `preserve-manual-memoization`, 2 `refs`).

## Tasks

- [x] T1 Fix the three lint errors.
- [x] T2 Upgrade Next, restore shadcn, declare the MCP SDK and zod.
- [x] T3 Clear high/critical advisories and pin the lint toolchain.
- [x] T4 Verify lint, typecheck, tests and build.
