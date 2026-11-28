// Route-level tests for POST /api/remittance-operations (create an operation from scratch in a conversation, crm_crear_operacion,
// migration 378). Covers auth gating, body validation, the beta-flag 404, RPC error-code mapping (42501/22023/P0002) and the
// happy-path response shape.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const USER_ID = "user-a";
const CONVERSATION_ID = "11111111-1111-1111-1111-111111111111";
const OPERATION_ID = "44444444-4444-4444-4444-444444444444";

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

function ctx(profileResult: { data: unknown; error: unknown }, rpcResult: { data: unknown; error: unknown }) {
  const rpc = vi.fn(() => Promise.resolve(rpcResult));
  const from = vi.fn(() => profileBuilder(profileResult));
  return { supabase: { from, rpc }, userId: USER_ID, accountId: "account-a", role: "agent" as const, account: { id: "account-a", name: "A" } };
}

function request(body?: unknown, rawBody?: string) {
  return new Request("http://local/api/remittance-operations", {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const GOOD = { conversationId: CONVERSATION_ID, servicio: "zelle", monto: 13000 };

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations", () => {
  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    expect((await POST(request(GOOD))).status).toBe(401);
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    expect((await POST(request(undefined, "{not-json"))).status).toBe(400);
  });

  it("malformed conversationId -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ ...GOOD, conversationId: "not-a-uuid" }));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("a service that is not one of the panel's services -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ ...GOOD, servicio: "paloma" }));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("an amount that is not a number -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ ...GOOD, monto: "mucho" }));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(GOOD));

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "42501", message: "insufficient_privilege" } }));

    expect((await POST(request(GOOD))).status).toBe(403);
  });

  it("RPC validation error (22023), e.g. a zero amount -> 400 with message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "22023", message: "amount must be greater than 0" } }));

    const response = await POST(request({ ...GOOD, monto: 0 }));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("amount must be greater than 0");
  });

  it("RPC not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "conversation not found" } }));

    expect((await POST(request(GOOD))).status).toBe(404);
  });

  it("success -> 200 { ok, id, service } and calls the RPC with the conversation, the service and the amount", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: { id: OPERATION_ID, service: "zelle" }, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(GOOD));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toEqual({ ok: true, id: OPERATION_ID, service: "zelle" });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_crear_operacion", {
      p_conversation_id: CONVERSATION_ID,
      p_servicio: "zelle",
      p_monto: 13000,
    });
  });

  it("a combo may go without an amount: the RPC gets null", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: { id: OPERATION_ID, service: "combo" }, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ conversationId: CONVERSATION_ID, servicio: "combo" }));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_crear_operacion", {
      p_conversation_id: CONVERSATION_ID,
      p_servicio: "combo",
      p_monto: null,
    });
  });
});
