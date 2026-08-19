// ============================================================
// The inbox session timer must behave EXACTLY as it did before
// the 24-hour logic moved out of `message-thread.tsx`.
//
// `PRE` below is the original inline implementation, copied
// verbatim from commit 568d96e. `POST` is the arithmetic the
// component runs today. The test drives both over every minute of
// the window plus the awkward shapes around it and asserts they
// never disagree.
//
// This is a differential test, not a specification: it is not
// asserting that the old behaviour was RIGHT. It documents one
// place where it is knowingly wrong — `24 - floor(hoursElapsed)`
// reads an hour generous — and pins it anyway. Operators have been
// reading that number for months; changing it is a product
// decision, not a side effect of moving code.
//
// When the rounding is eventually fixed, this file is what has to
// be deleted, deliberately, in the same commit.
// ============================================================

import { describe, it, expect } from "vitest";
import { differenceInHours } from "date-fns";
import {
  lastCustomerMessageAt,
  sessionWindowFromMessages,
  type SessionWindowMessage,
} from "./session-window";

/** Stand-in for next-intl's `t`, so both sides format identically. */
const tTimer = (key: string, vals?: Record<string, number>) =>
  vals ? `${key}:${JSON.stringify(vals)}` : key;

/** Verbatim from message-thread.tsx at 568d96e. */
function PRE(messages: SessionWindowMessage[]) {
  if (!messages.length) return { expired: false, remaining: "" };

  const lastCustomerMsg = [...messages]
    .reverse()
    .find((m) => m.sender_type === "customer");

  if (!lastCustomerMsg)
    return { expired: true, remaining: "No customer messages" };

  const hoursSince = differenceInHours(
    new Date(),
    new Date(lastCustomerMsg.created_at),
  );
  const expired = hoursSince >= 24;

  if (expired) return { expired: true, remaining: tTimer("expired") };

  const hoursLeft = 24 - hoursSince;
  const remaining =
    hoursLeft >= 1
      ? tTimer("xhRemaining", { hours: Math.floor(hoursLeft) })
      : tTimer("xmRemaining", { minutes: Math.floor(hoursLeft * 60) });

  return { expired, remaining };
}

/** What `message-thread.tsx` computes today. Keep in sync with it. */
function POST(messages: SessionWindowMessage[]) {
  const window = sessionWindowFromMessages(messages);

  if (window.state === "unknown") return { expired: false, remaining: "" };
  if (window.state === "expired") {
    const everWrote = lastCustomerMessageAt(messages) !== null;
    return {
      expired: true,
      remaining: everWrote ? tTimer("expired") : "No customer messages",
    };
  }

  const remaining =
    window.hoursLeft >= 1
      ? tTimer("xhRemaining", { hours: window.hoursLeft })
      : tTimer("xmRemaining", { minutes: Math.floor(window.hoursLeft * 60) });

  return { expired: false, remaining };
}

const ago = (minutes: number) =>
  new Date(Date.now() - minutes * 60_000).toISOString();

describe("inbox session timer — PRE vs POST", () => {
  it("agrees on every minute of the window and well past it", () => {
    const disagreements: string[] = [];
    // 0 → 26 h in one-minute steps: covers the whole open window, the
    // exact 24 h boundary, and two hours past it.
    for (let min = 0; min <= 26 * 60; min++) {
      const msgs = [{ sender_type: "customer", created_at: ago(min) }];
      const pre = JSON.stringify(PRE(msgs));
      const post = JSON.stringify(POST(msgs));
      if (pre !== post) disagreements.push(`${min}m: ${pre} vs ${post}`);
    }
    expect(disagreements).toEqual([]);
  });

  it("agrees on the empty thread", () => {
    expect(POST([])).toEqual(PRE([]));
    // Specifically: NOT expired, so the composer isn't greyed out.
    expect(POST([])).toEqual({ expired: false, remaining: "" });
  });

  it("agrees when the customer never wrote", () => {
    for (const senders of [["agent"], ["bot"], ["agent", "bot", "agent"]]) {
      const msgs = senders.map((s, i) => ({
        sender_type: s,
        created_at: ago(i + 1),
      }));
      expect(POST(msgs)).toEqual(PRE(msgs));
    }
    // And keeps the original's distinct wording for it.
    expect(POST([{ sender_type: "agent", created_at: ago(1) }])).toEqual({
      expired: true,
      remaining: "No customer messages",
    });
  });

  it("agrees that an agent reply does not extend the window", () => {
    for (const min of [1, 59, 60, 1439, 1440, 1441, 2000]) {
      const msgs = [
        { sender_type: "customer", created_at: ago(min) },
        { sender_type: "agent", created_at: ago(1) },
      ];
      expect(POST(msgs), `customer ${min}m ago`).toEqual(PRE(msgs));
    }
  });

  it("agrees on multi-customer and clock-skewed threads", () => {
    const twoCustomers = [
      { sender_type: "customer", created_at: ago(2000) },
      { sender_type: "customer", created_at: ago(30) },
    ];
    expect(POST(twoCustomers)).toEqual(PRE(twoCustomers));

    const future = [
      {
        sender_type: "customer",
        created_at: new Date(Date.now() + 3_600_000).toISOString(),
      },
    ];
    expect(POST(future)).toEqual(PRE(future));
  });

  it("still reads one hour generous, exactly as it always has", () => {
    // 5 h 30 m elapsed → "19h left", not 18. Pinned on purpose; see
    // the header. If this fails, someone fixed the rounding — that is
    // a product change and this whole file should go with it.
    const msgs = [{ sender_type: "customer", created_at: ago(330) }];
    expect(POST(msgs).remaining).toBe('xhRemaining:{"hours":19}');
    expect(POST(msgs)).toEqual(PRE(msgs));
  });
});
