import { describe, expect, it } from "vitest";
import { createChatSoundGate } from "./chat-sound-gate";

function msg(overrides: Partial<Parameters<ReturnType<typeof createChatSoundGate>["shouldRing"]>[0]> = {}) {
  return {
    sender_type: "customer" as const,
    conversation_id: "conv-1",
    created_at: "2026-09-28T12:00:00.000Z",
    ...overrides,
  };
}

describe("createChatSoundGate", () => {
  it("rings for a new inbound customer message in a background conversation", () => {
    const gate = createChatSoundGate();
    expect(gate.shouldRing(msg(), null)).toBe(true);
  });

  it("does not ring for outbound agent messages", () => {
    const gate = createChatSoundGate();
    expect(gate.shouldRing(msg({ sender_type: "agent" }), null)).toBe(false);
  });

  it("does not ring for outbound bot messages", () => {
    const gate = createChatSoundGate();
    expect(gate.shouldRing(msg({ sender_type: "bot" }), null)).toBe(false);
  });

  it("does not ring for the conversation the agent currently has open", () => {
    const gate = createChatSoundGate();
    expect(gate.shouldRing(msg({ conversation_id: "conv-1" }), "conv-1")).toBe(
      false,
    );
  });

  it("still rings for a different conversation while one is open", () => {
    const gate = createChatSoundGate();
    expect(gate.shouldRing(msg({ conversation_id: "conv-2" }), "conv-1")).toBe(
      true,
    );
  });

  it("stops ringing for messages created at/before mark-all-read", () => {
    const gate = createChatSoundGate();
    const markedAt = new Date("2026-09-28T12:00:05.000Z").getTime();
    gate.muteUntilNow(markedAt);

    expect(
      gate.shouldRing(
        msg({ created_at: "2026-09-28T12:00:00.000Z" }),
        null,
      ),
    ).toBe(false);
    // Exactly at the boundary also counts as "already read".
    expect(
      gate.shouldRing(
        msg({ created_at: "2026-09-28T12:00:05.000Z" }),
        null,
      ),
    ).toBe(false);
  });

  it("rings again for genuinely new messages that arrive after mark-all-read", () => {
    const gate = createChatSoundGate();
    gate.muteUntilNow(new Date("2026-09-28T12:00:05.000Z").getTime());

    expect(
      gate.shouldRing(
        msg({ created_at: "2026-09-28T12:00:06.000Z" }),
        null,
      ),
    ).toBe(true);
  });

  it("defaults muteUntilNow() to the current time when called with no argument", () => {
    const gate = createChatSoundGate();
    const before = Date.now();
    gate.muteUntilNow();
    const after = Date.now();

    // A message created anywhere in [before, after] must be suppressed —
    // it can only be one already accounted for by "mark all as read".
    expect(
      gate.shouldRing(
        msg({ created_at: new Date(before).toISOString() }),
        null,
      ),
    ).toBe(false);
    void after;
  });
});
