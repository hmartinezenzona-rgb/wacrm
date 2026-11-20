// Spec: odd/tasks/pause-without-reason-expires.md (T1). The panel pause has no handoff reason and, since
// migration 385, expires after 5 minutes without human activity like the agent_replied pause. The minutes
// must count from the click, so the pause stamps ai_handoff_at; resuming clears it as before.

import { beforeEach, describe, expect, it, vi } from "vitest";

const updates: Record<string, unknown>[] = [];

function fakeSupabase() {
  const chain = {
    select: () => chain,
    eq: () => chain,
    maybeSingle: async () => ({ data: { id: "conv-1" }, error: null }),
    update: (values: Record<string, unknown>) => {
      updates.push(values);
      const done = { eq: () => done, then: (resolve: (v: unknown) => unknown) => resolve({ error: null }) };
      return done;
    },
  };
  return { from: () => chain };
}

vi.mock("@/lib/auth/account", () => ({
  requireRole: async () => ({ supabase: fakeSupabase(), accountId: "acc-1", userId: "user-1" }),
  toErrorResponse: (error: unknown) => {
    throw error;
  },
}));

vi.mock("@/lib/rate-limit", () => ({
  checkRateLimit: () => ({ success: true }),
  rateLimitResponse: () => new Response(null, { status: 429 }),
  RATE_LIMITS: { send: {} },
}));

function post(body: unknown) {
  return new Request("http://localhost/api/ai/autoreply/conv-1", { method: "POST", body: JSON.stringify(body) });
}

const params = { params: Promise.resolve({ conversationId: "conv-1" }) };

beforeEach(() => {
  updates.length = 0;
});

describe("POST /api/ai/autoreply/[conversationId]", () => {
  it("pausing stamps ai_handoff_at with the current time and leaves the reason empty", async () => {
    const { POST } = await import("./route");
    const before = Date.now();

    const response = await POST(post({ paused: true }), params);

    expect(response.status).toBe(200);
    expect(updates).toHaveLength(1);
    expect(updates[0].ai_autoreply_disabled).toBe(true);
    expect(updates[0]).not.toHaveProperty("ai_handoff_reason");
    const stamped = Date.parse(String(updates[0].ai_handoff_at));
    expect(stamped).toBeGreaterThanOrEqual(before);
    expect(stamped).toBeLessThanOrEqual(Date.now());
  });

  it("resuming clears the pause, the reason and the handoff time", async () => {
    const { POST } = await import("./route");

    await POST(post({ paused: false }), params);

    expect(updates[0]).toMatchObject({
      ai_autoreply_disabled: false,
      ai_handoff_reason: null,
      ai_handoff_at: null,
      assigned_agent_id: null,
    });
  });
});
