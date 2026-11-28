# Measurements

Method: production panel, fresh session, heaviest conversation (1,100 messages), `PerformanceResourceTiming` collected from a mark set immediately before the click. Browser devtools resource timeline, no cache warm-up. Owner-approved temporary admin user, deleted after the run.

## Baseline 2026-11-27 (before any change)

| t after click | Event | Detail |
|---|---|---|
| 0 ms | click | mark set |
| 1,920 ms | `messages` query starts | duration 463 ms; **no resource entry exists between 0 and 1,920 ms** |
| 2,383 ms | messages on screen | |
| 2,520 ms | 29 byte-proxy requests `/api/chat-media/account/...` | 494–3,023 ms each |
| 2,587 ms | `/api/chat-media/sign` starts | 2,962 ms |
| 5,549 ms | signing finishes | |
| 5,610 ms | first signed Storage URL request | 37 signed requests, 436–621 ms each |

Page payload: last 50 messages carry 50 media objects = 5,314 kB (avg 106 kB, max 818 kB).

Database: thread page query 1.59 ms, conversation list 0.47 ms (read-only user, RLS not included).

## T1.0 — classification of the 1,920 ms pre-fetch window

**Measured fact: the gap contains no network activity.** The resource timeline has no entry between the mark and the `messages` query, so the window is not waiting on Supabase, auth HTTP calls, or media. It is time spent on the main thread or in a scheduled callback after the click.

What it rules out:

- Hypothesis (a) — a Supabase auth lock before the first PostgREST call — is **not excluded** by the resource timeline: a lock held inside JS produces no network entry. It stays open.
- Hypothesis "network latency to Supabase" is **excluded**.
- Hypothesis "waiting for the sign round-trip" is **excluded**; signing happens later.

What remains open and needs a Chrome Performance trace (long tasks vs idle):

- Synchronous render work in the inbox shell after the click.
- A deferred `useEffect`/scheduler delay before the thread fetch.
- An auth-lock handoff inside supabase-js.

**Status: partially classified.** The gap is not network. Slice 1 removes the separate sign round-trip but is not expected to remove this window unless the trace shows it is the auth lock; that check is recorded again after slice 4.

## After slice 1

Slice 1 code landed 2026-11-27 (commit for `feat(inbox): serve thread page with signed media map`). What it changes in this timeline, without new numbers:

- The separate `/api/chat-media/sign` round-trip (2,587 → 5,549 ms in the baseline) is expected to disappear from the open path: the thread page response now carries `signed` for the page's media and the client seeds it before rendering.
- The 1,920 ms pre-fetch window is **not** addressed by slice 1. The T1.0 record already classified it as zero network activity, and the client PostgREST page call is replaced by the route call without changing when the fetch is issued.
- `/api/chat-media/...` byte-proxy requests for first-page media should drop to zero unless signing fails; that claim is unmeasured until the staging run.

**Status: measured after slice 4** — see the section below. The separate sign round-trip is gone and the byte proxy is unused.

## After slice 4 (staging, production build, 2026-11-27)

Environment: branch `feat/inbox-media-performance` at `8aefd168`, `next build` + `next start` on `localhost:3101`, Supabase staging. Fixture: one `PRUEBA Rendimiento` conversation, 160 messages, 55 images averaging 171 KB (9,418 KB total in storage). Browser: cold navigation to `/inbox`, then click on the thread row; resource timings read from `PerformanceResourceTiming` relative to that click.

| Run | `/api/inbox/messages` start | duration | first media start | media objects | proxy requests | same-origin JSON |
| --- | --- | --- | --- | --- | --- | --- |
| cold open | 19 ms | 632 ms | 786 ms | 4 | 0 | 5 KB |
| repeat 1 | 4 ms | 372 ms | 501 ms | 4 | 0 | 5 KB |
| repeat 2 | 7 ms | 469 ms | 595 ms | 4 | 0 | 5 KB |
| repeat 3 | 4 ms | 552 ms | 675 ms | 4 | 0 | 5 KB |

First-paint media bytes measured on the four rendered `<img>` elements: 173,996 / 176,061 / 175,989 / 174,078 B = **684 KB**, against 55 objects (9,418 KB) stored for the thread. Virtualized DOM held 4 rows and 10 `<img>` elements.

What the numbers support:

- The separate signing round-trip is gone from the open path: no `/api/chat-media/sign` request appears, and the page no longer issues one.
- The byte proxy is unused: zero `/api/media` requests; every media load goes to the signed Storage URL returned by the thread page.
- Bytes per open drop from page-size (5.3 MB in the production baseline) to 684 KB, bounded by what is visible, not by thread size.
- No console error or warning, and no React error boundary during repeated opens, after `8aefd168`.

What these numbers do **not** support:

- They are not comparable millisecond-for-millisecond with the production baseline. The baseline was measured in production (browser → Supabase cloud, real network); this run is a local production build against staging.
- The 501–675 ms repeat figures benefit from warm connections established by the cold open (786 ms). Use the cold number for a first-visit estimate.
- T4.4 (visual check of virtualization while scrolling) still needs a human pass.
- The dominant remaining cost is server-side in `/api/inbox/messages`: 372–632 ms for one page of 50 messages, of which the signing of 50 Storage paths is the known large term. Not yet profiled (slice 4b is gated on a Performance trace).

## After slice 4c (staging, production build, 2026-11-27)

Profiling first, on the same staging fixture, standalone against the same Supabase project:

| Stage | 10 paths | 51–55 paths | chunks of 13 / 26 |
| --- | --- | --- | --- |
| `createSignedUrls` | 92–121 ms | 110–614 ms (median ~140) | 107–273 ms |
| messages page query | — | 99–213 ms | — |

Two conclusions, one of them the opposite of the working assumption:

- Signing is **fixed latency, not per-path work**. A batch of 55 costs the same as a batch of 10; splitting it into parallel chunks does not help and can hurt. Capping the batch or parallelizing it would have been wasted work.
- The endpoint's real cost is a chain of **four serial network stages**: profile → accounts → (membership ∥ page) → signing. The `accounts` lookup supplies only `account.name`, which the thread route never reads.

Two changes, then the same measurement method:

1. `requireScopedRole(min)` resolves identity, account id and role from `profiles` alone; the thread route uses it. One round trip removed.
2. Issued signatures are reused by account + path while the remaining life covers the requested TTL. Reopening a thread or paging back into history no longer pays Storage at all.

| Run | before: endpoint | after: endpoint | before: first media | after: first media |
| --- | --- | --- | --- | --- |
| cold open | 632 ms | 696 ms | 786 ms | 843 ms |
| repeat 1 | 372 ms | 278 ms | 501 ms | 399 ms |
| repeat 2 | 469 ms | 271 ms | 595 ms | 400 ms |
| repeat 3 | 552 ms | 351 ms | 675 ms | 481 ms |
| repeat 4–7 | — | 295 / 389 / 299 / 268 ms | — | 415 / 516 / 427 / 393 ms |

**Median on a repeat open: endpoint 469 → 295 ms, first media 595 → 415 ms.** Proxy requests stayed at 0 and media objects stayed at 4.

## Correction to slice 4c (2026-11-28)

The numbers above were produced by a build whose signature cache **never reused an entry**: it stored `expiresAt = now + ttl` and only reused while `expiresAt - now >= ttl`, which holds only inside the same millisecond. Every page after the first re-signed everything, and the unit tests passed because both calls landed in that same millisecond.

So the improvement measured above came from removing the `accounts` round trip, not from the cache. Re-running after the cache was fixed:

| Run | endpoint | first media | media objects | proxy |
| --- | --- | --- | --- | --- |
| first open after page load | 378 ms | 526 ms | 4 | 0 |
| repeat 1 | 191 ms | not requested (HTTP cache) | 0 | 0 |
| repeat 2 | 177 ms | not requested (HTTP cache) | 0 | 0 |
| repeat 3 | 192 ms | not requested (HTTP cache) | 0 | 0 |
| repeat 4 | 195 ms | 325 ms | 4 | 0 |

**Repeat-open endpoint median: 469 ms before 4c → ~192 ms after.** The repeats show zero media requests because the reused signature is the same URL the browser already holds, so the HTTP cache answers. That is the intended behaviour of reusing a signature, not a saving in bytes.

What did not change: the cold first open is dominated by connection setup and stays in the 380–700 ms band depending on the run; the cache cannot help a request that has nothing cached yet.

## TM2 in production (2026-11-28, release fb3a8299)

Slices 1–4c published to production: served BUILD_ID `-7DudTEVohhunlO9V5SgY`, commit `fb3a8299`, previous served `5e934e11` kept for rollback. Measured on the live panel with an owner-approved temporary admin, deleted afterwards; browser cache bypassed for the cold run.

| Run | conversation | endpoint | first media | media objects | proxy requests | payload |
| --- | --- | --- | --- | --- | --- | --- |
| cold (cache bypassed) | Osmany Services (13 days) | 211 ms | 417 ms | 6 | 0 | 7 KB |
| warm | Osmany Services | 241 / 265 ms | 407 / 418 ms | 6 | 0 | — |
| warm | Adrismira | 296 / 185 ms | 459 / 360 ms | 2 | 0 | — |
| warm | Leydy Mary | 267 / 161 ms | 407 ms | 2 | 0 | — |

Against the production baseline measured before any change on the heaviest conversation: **first media 5,610 → 417 ms**, **proxy requests 29 → 0**, **media objects ~50 → 6**, **bytes 5.3 MB → 417 ms of visible media only**.

What these numbers support:

- The thread page is served by the route, with media signed inside the same response: no separate sign call appears in the timeline.
- Only visible media is downloaded. The byte proxy is not used at all in any conversation measured.
- Users scroll and switch threads in production without the React #310 crash that an earlier build had.

What they do not support:

- The conversation measured is not the same one as the baseline's heaviest thread, and the message count differs; the comparison is structural and order-of-magnitude, not an A/B on identical data.
- These are single-day measurements on one connection; a slow mobile network will shift every number.
- The quote-jump behaviour was confirmed in production on 2026-11-28 (conversation `LEAND`, reply `4a09321a` -> quoted `73681f28`): the ring appeared within 100 ms, the quoted row was fully in the viewport and the thread scrolled up 2,685 -> 2,425 px instead of clamping to the newest message.



What these numbers do not support:

- The cold open did not improve measurably (632 → 696 ms, one sample each). It is dominated by connection setup to Supabase, which neither change touches.
- The signature cache is per server process. A second instance, a restart, or a serverless cold start pays the signing round trip again; the win is per-instance, not global.
- Neither change makes the first paint faster by itself: messages and signatures still arrive in the same response. Removing the signing stage from the critical path is a separate design change and is not claimed here.

