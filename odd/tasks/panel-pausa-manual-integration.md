# panel-pausa-manual-integration

**Objective**: bring production's `fa51b1e0` (manual vs automatic bot pause) into `feat/port-chat-operations-calculator` so a future panel publication from this branch does not regress the 21-nov owner decision.

**Problem**: production panel runs `fa51b1e0` (`release/prod-pausa-manual`); the feature branch diverged from the same base `0c4471e9` and never received that fix. Building HEAD as-is would lose the separation between manual pause (never expires) and automatic pause (`agent_replied`, released by cron after 5 min).

**Evidence**
- Merge base: `0c4471e9`.
- `git diff 0c4471e9 HEAD` over the five files `fa51b1e0` touches is empty: the intermediate commits `65b7a858` + `1a3000b2` and `e92ec529` + `57248e1f` are exact reverts, so HEAD neither contains nor contradicts the fix.
- `fa51b1e0` changes only: `messages/{es,en}.json`, `src/app/api/ai/autoreply/[conversationId]/route.ts`, `src/components/inbox/contact-sidebar.tsx` and its test.

**Scope**
- In: merge `privado/release/prod-pausa-manual` into the feature branch; verify the five files match production; run typecheck and the inbox/autoreply tests.
- Out: publishing the panel (separate explicit go-ahead), migration changes (none needed).

**Checks**: `npx tsc --noEmit`; `npx vitest run src/components/inbox src/app/api/ai/autoreply`; `git diff fa51b1e0..HEAD -- <the five files>` empty.

## Tasks

- [x] T1 Commit this plan, merge `privado/release/prod-pausa-manual` into the feature branch.
  - Merge commit `1ed446a0`, no conflicts; 5 files, +100/-9.
- [x] T2 Verify file parity with production and run typecheck + targeted tests.
  - `git diff fa51b1e0 HEAD` over the five affected paths: empty.
  - `npx tsc --noEmit`: exit 0.
  - Full suite: 305 files, 4224 tests passed (25.8 s).
  - The four files from the other session remain untouched.
