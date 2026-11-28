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

**Status: unmeasured.** The staging browser check (T1.8) and the TM1 numbers have not been produced in this run. No success criterion is claimed as met.

## After slice 4

To be recorded when the slice ships.
