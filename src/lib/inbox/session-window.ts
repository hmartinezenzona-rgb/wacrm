// ============================================================
// WhatsApp's 24-hour customer service window.
//
// Meta only accepts free-form messages (text, image, audio,
// document, interactive) within 24 hours of the customer's last
// inbound message. Outside it, only approved templates go through.
//
// This lived inline in `message-thread.tsx` as the inbox session
// timer. It moved here because the pipelines board now needs the
// same answer before it offers to send a delivery proof — and two
// different implementations of "24 hours" is exactly the kind of
// drift that produces a message the operator thinks was sent.
//
// The module is deliberately transport-free: it takes timestamps,
// not a Supabase client, so both callers can feed it whatever they
// already have (the inbox has the loaded messages; the deal form
// has a single `max(created_at)` from a query).
//
// This is a BEHAVIOUR-PRESERVING extraction. `hoursLeft` keeps the
// inbox's original arithmetic — whole elapsed hours subtracted from
// 24 — even though it reads one hour generous (5 h 30 m elapsed
// shows "19h left", not 18). Changing what operators have been
// reading for months is a product decision, not a side effect of
// moving code. `msLeft` is exposed for callers that want the exact
// figure.
// ============================================================

export const SESSION_WINDOW_HOURS = 24;

/**
 * - `open`     — a customer message landed under 24 h ago; free-form sends work.
 * - `expired`  — over 24 h, or the customer never wrote; only templates work.
 * - `unknown`  — nothing to judge from (no messages loaded yet).
 *
 * `unknown` is NOT the same as `expired`. The inbox composer treats it
 * as "don't block", which is the pre-existing behaviour for a thread
 * whose messages haven't loaded: blocking on an empty array would grey
 * out the composer on every mount.
 */
export type SessionWindowState = "open" | "expired" | "unknown";

export interface SessionWindow {
  state: SessionWindowState;
  /** Convenience for callers that only gate on "can I send free-form?". */
  expired: boolean;
  /**
   * Whole hours left, using the inbox's historical rounding
   * (`24 - floor(hoursElapsed)`). 0 unless `state === "open"`.
   * Can exceed 24 when the stored timestamp is ahead of the browser
   * clock — see the note in `sessionWindowFrom`.
   */
  hoursLeft: number;
  /** Exact milliseconds left in the window. 0 unless `state === "open"`. */
  msLeft: number;
}

/** The shape this module needs from a message row — nothing more. */
export interface SessionWindowMessage {
  sender_type?: string | null;
  created_at: string;
}

const HOUR_MS = 60 * 60 * 1000;

const CLOSED = (state: SessionWindowState): SessionWindow => ({
  state,
  expired: state === "expired",
  hoursLeft: 0,
  msLeft: 0,
});

/**
 * The window as of `now`, given when the customer last wrote.
 *
 * `null` means the customer never wrote in this thread, which is
 * `expired`: there is no window to send free-form into. That mirrors
 * the inbox's long-standing "No customer messages" state.
 *
 * The cutoff uses whole elapsed hours, matching the `differenceInHours`
 * the inbox has always used — so a thread at 23 h 59 m is still open,
 * and one at exactly 24 h is not.
 */
export function sessionWindowFrom(
  lastCustomerAt: string | Date | null | undefined,
  now: Date = new Date(),
): SessionWindow {
  if (!lastCustomerAt) return CLOSED("expired");

  const last =
    lastCustomerAt instanceof Date ? lastCustomerAt : new Date(lastCustomerAt);
  if (Number.isNaN(last.getTime())) return CLOSED("expired");

  // Deliberately NOT clamped at zero. A timestamp in the future — clock
  // skew between the database and the browser — yields a negative
  // elapsed time, so the window reads as open with more than 24 h left.
  // That is what the inbox has always shown, and `session-window.parity.test.ts`
  // holds it there. Clamping would be a display fix, and this module is
  // an extraction, not a redesign. Either way the answer to the only
  // question that gates a send — `expired` — is the same: not expired.
  const elapsedMs = now.getTime() - last.getTime();
  const hoursSince = Math.floor(elapsedMs / HOUR_MS);
  if (hoursSince >= SESSION_WINDOW_HOURS) return CLOSED("expired");

  return {
    state: "open",
    expired: false,
    hoursLeft: SESSION_WINDOW_HOURS - hoursSince,
    msLeft: SESSION_WINDOW_HOURS * HOUR_MS - elapsedMs,
  };
}

/** Timestamp of the newest customer message, or `null` if there is none. */
export function lastCustomerMessageAt(
  messages: readonly SessionWindowMessage[],
): string | null {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].sender_type === "customer") return messages[i].created_at;
  }
  return null;
}

/**
 * The window for a loaded thread. An empty array is `unknown`, not
 * `expired` — see the note on `SessionWindowState`.
 */
export function sessionWindowFromMessages(
  messages: readonly SessionWindowMessage[],
  now: Date = new Date(),
): SessionWindow {
  if (messages.length === 0) return CLOSED("unknown");
  return sessionWindowFrom(lastCustomerMessageAt(messages), now);
}
