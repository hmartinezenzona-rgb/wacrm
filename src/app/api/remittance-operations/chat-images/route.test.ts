// Route-level tests for GET /api/remittance-operations/chat-images?conversationId=<uuid>.
// The picker for a cash recipient's ID photo: the image messages of one conversation via
// crm_imagenes_de_conversacion (migration 233). Auth gating, conversationId validation, the beta-flag 404,
// RPC error mapping and the mapped response shape.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const CONVERSATION_ID = "11111111-1111-1111-1111-111111111111";
const ENABLED_PROFILE = { data: { beta_features: ["operations_panel"] }, error: null };
const DISABLED_PROFILE = { data: { beta_features: [] }, error: null };

function profileBuilder(result: { data: unknown; error: unknown }) {
  const builder = {
    select: vi.fn(() => builder),
    eq: vi.fn(() => builder),
    maybeSingle: vi.fn(() => Promise.resolve(result)),
  };
  return builder;
}

function ctx(
  profileResult: { data: unknown; error: unknown },
  rpcResult: { data: unknown; error: unknown },
) {
  const rpc = vi.fn(() => Promise.resolve(rpcResult));
  const from = vi.fn(() => profileBuilder(profileResult));
  return { supabase: { from, rpc }, userId: "user-a", accountId: "account-a", role: "viewer" as const };
}

function request(query = `?conversationId=${CONVERSATION_ID}`) {
  return new Request(`http://local/api/remittance-operations/chat-images${query}`);
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/remittance-operations/chat-images", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });
    expect((await GET(request())).status).toBe(401);
  });

  it("missing or malformed conversationId -> 400", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: [], error: null }));
    expect((await GET(request(""))).status).toBe(400);
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: [], error: null }));
    expect((await GET(request("?conversationId=nope"))).status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: [], error: null });
    requireRole.mockResolvedValueOnce(callCtx);
    expect((await GET(request())).status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "42501", message: "insufficient_privilege" } }),
    );
    expect((await GET(request())).status).toBe(403);
  });

  it("success -> the images mapped to camelCase, newest first as the RPC returned them", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, {
      data: [
        { id: "m2", message_id: "wamid.2", created_at: "2026-10-08T16:35:00Z", sender_type: "customer", media_url: "https://x/2.jpg" },
        { id: "m1", message_id: "wamid.1", created_at: "2026-10-08T14:02:00Z", sender_type: "agent", media_url: "https://x/1.jpg" },
      ],
      error: null,
    });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request());
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toEqual({
      images: [
        { id: "m2", wamid: "wamid.2", createdAt: "2026-10-08T16:35:00Z", senderType: "customer", mediaUrl: "https://x/2.jpg" },
        { id: "m1", wamid: "wamid.1", createdAt: "2026-10-08T14:02:00Z", senderType: "agent", mediaUrl: "https://x/1.jpg" },
      ],
    });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_imagenes_de_conversacion", {
      p_conversation_id: CONVERSATION_ID,
    });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("an unexpected RPC error -> 500 without leaking the message", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "XX000", message: "boom" } }));
    const response = await GET(request());
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain("boom");
  });
});
