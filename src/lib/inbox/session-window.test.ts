import { describe, it, expect } from "vitest";
import {
  SESSION_WINDOW_HOURS,
  lastCustomerMessageAt,
  sessionWindowFrom,
  sessionWindowFromMessages,
} from "./session-window";

const NOW = new Date("2026-08-18T12:00:00.000Z");

/** `hours` before NOW, as an ISO string. */
function ago(hours: number, minutes = 0): string {
  return new Date(
    NOW.getTime() - hours * 3_600_000 - minutes * 60_000,
  ).toISOString();
}

describe("sessionWindowFrom", () => {
  it("is open just under 24 hours", () => {
    const w = sessionWindowFrom(ago(23, 59), NOW);
    expect(w.state).toBe("open");
    expect(w.expired).toBe(false);
  });

  it("is expired at exactly 24 hours", () => {
    const w = sessionWindowFrom(ago(SESSION_WINDOW_HOURS), NOW);
    expect(w.state).toBe("expired");
    expect(w.expired).toBe(true);
    expect(w.hoursLeft).toBe(0);
  });

  it("treats a customer that never wrote as expired", () => {
    expect(sessionWindowFrom(null, NOW).expired).toBe(true);
    expect(sessionWindowFrom(undefined, NOW).expired).toBe(true);
  });

  it("treats an unparseable timestamp as expired rather than open", () => {
    expect(sessionWindowFrom("not a date", NOW).expired).toBe(true);
  });

  it("keeps the inbox's historical hour arithmetic", () => {
    // 5 h 30 m elapsed reads as "19h left", not 18 — see the note in
    // session-window.ts. This test exists to catch an accidental
    // "fix" that would silently change what operators read.
    expect(sessionWindowFrom(ago(5, 30), NOW).hoursLeft).toBe(19);
    expect(sessionWindowFrom(ago(0, 1), NOW).hoursLeft).toBe(24);
    expect(sessionWindowFrom(ago(23, 1), NOW).hoursLeft).toBe(1);
  });

  it("reports exact milliseconds left alongside the rounded hours", () => {
    const w = sessionWindowFrom(ago(5, 30), NOW);
    expect(w.msLeft).toBe(18.5 * 3_600_000);
  });

  it("reads a future timestamp as a fresh message, not an expired one", () => {
    // Clock skew between the database and the browser. The window is
    // open — which is the only thing that gates a send — and the hours
    // shown run past 24, exactly as the inbox has always shown them.
    const future = new Date(NOW.getTime() + 3_600_000).toISOString();
    const w = sessionWindowFrom(future, NOW);
    expect(w.state).toBe("open");
    expect(w.expired).toBe(false);
    expect(w.hoursLeft).toBe(SESSION_WINDOW_HOURS + 1);
  });

  it("accepts a Date as well as an ISO string", () => {
    expect(sessionWindowFrom(new Date(ago(1)), NOW).state).toBe("open");
  });
});

describe("lastCustomerMessageAt", () => {
  it("returns the newest customer message, ignoring agent traffic", () => {
    const at = lastCustomerMessageAt([
      { sender_type: "customer", created_at: ago(10) },
      { sender_type: "customer", created_at: ago(3) },
      { sender_type: "agent", created_at: ago(1) },
    ]);
    expect(at).toBe(ago(3));
  });

  it("returns null when only the agent has spoken", () => {
    expect(
      lastCustomerMessageAt([
        { sender_type: "agent", created_at: ago(1) },
        { sender_type: "bot", created_at: ago(2) },
      ]),
    ).toBeNull();
  });
});

describe("sessionWindowFromMessages", () => {
  it("is unknown — not expired — for an unloaded thread", () => {
    const w = sessionWindowFromMessages([], NOW);
    expect(w.state).toBe("unknown");
    // The inbox composer keys off `expired`; flipping this to true
    // would grey out the composer on every mount.
    expect(w.expired).toBe(false);
  });

  it("is expired when the thread has no customer message at all", () => {
    const w = sessionWindowFromMessages(
      [{ sender_type: "agent", created_at: ago(1) }],
      NOW,
    );
    expect(w.state).toBe("expired");
  });

  it("uses the last customer message even when an agent replied after", () => {
    const w = sessionWindowFromMessages(
      [
        { sender_type: "customer", created_at: ago(30) },
        { sender_type: "agent", created_at: ago(2) },
      ],
      NOW,
    );
    expect(w.expired).toBe(true);
  });
});
