// Route-level tests for POST /api/remittance-operations/{operationId}/status (crm_cambiar_estado, migration 379): auth gating,
// operationId and body validation, the beta-flag 404, RPC error mapping (42501/22023/P0002) and the happy-path response.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const USER_ID = "user-a";
const OPERATION_ID = "11111111-1111-1111-1111-111111111111";

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
  return new Request(`http://local/api/remittance-operations/${OPERATION_ID}/status`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const paramsFor = (operationId: string) => ({ params: Promise.resolve({ operationId }) });
const GOOD = { estado: "deposit_verification", notify: false };

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/status", () => {
  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    expect((await POST(request(GOOD), paramsFor(OPERATION_ID))).status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    expect((await POST(request(GOOD), paramsFor("not-a-uuid"))).status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(GOOD), paramsFor(OPERATION_ID));

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    expect((await POST(request(undefined, "{not-json"), paramsFor(OPERATION_ID))).status).toBe(400);
  });

  it("a state that is not one of the four allowed -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    for (const estado of ["completed", "cancelled", "transferring", "paloma", undefined]) {
      const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
      requireRole.mockResolvedValueOnce(callCtx);

      const response = await POST(request({ estado }), paramsFor(OPERATION_ID));

      expect(response.status, String(estado)).toBe(400);
      expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
    }
  });

  it("RPC insufficient_privilege (42501) -> 403, validation (22023) -> 400 with message, not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "42501", message: "insufficient_privilege" } }));
    expect((await POST(request(GOOD), paramsFor(OPERATION_ID))).status).toBe(403);

    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "22023", message: "operation is closed" } }));
    const refused = await POST(request(GOOD), paramsFor(OPERATION_ID));
    expect(refused.status).toBe(400);
    expect((await refused.json()).error).toBe("operation is closed");

    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "operation not found" } }));
    expect((await POST(request(GOOD), paramsFor(OPERATION_ID))).status).toBe(404);
  });

  it("success -> 200 with the RPC's answer and calls the RPC with the state and the bell", async () => {
    const { POST } = await import("./route");
    const answer = { operation_id: OPERATION_ID, changed: true, previous: "collecting_information", new_status: "ready_to_transfer" };
    const callCtx = ctx(ENABLED_PROFILE, { data: answer, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ estado: "ready_to_transfer", notify: true }), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toEqual({ ok: true, changed: true, newStatus: "ready_to_transfer" });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_cambiar_estado", {
      p_operation_id: OPERATION_ID,
      p_estado: "ready_to_transfer",
      p_notify: true,
    });
  });

  it("the bell defaults to off", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: { changed: true, new_status: "awaiting_deposit" }, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    await POST(request({ estado: "awaiting_deposit" }), paramsFor(OPERATION_ID));

    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_cambiar_estado", {
      p_operation_id: OPERATION_ID,
      p_estado: "awaiting_deposit",
      p_notify: false,
    });
  });
});
