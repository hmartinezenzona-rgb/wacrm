// Route-level tests for POST /api/remittance-operations/{operationId}/move-deposit  { transId, destino? } (crm_mover_deposito, migration 381): auth
// gating, operationId and body validation, the beta-flag 404, RPC error mapping (42501/22023/P0002) and the happy-path response.

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
const TARGET_ID = "22222222-2222-2222-2222-222222222222";

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
  return new Request(`http://local/api/remittance-operations/${OPERATION_ID}/move-deposit`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const paramsFor = (operationId: string) => ({ params: Promise.resolve({ operationId }) });
const GOOD = { transId: "10400000009977", destino: TARGET_ID };

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/move-deposit", () => {
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

  it("invalid JSON body, a missing transId and a malformed destino -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    for (const make of [() => request(undefined, "{not-json"), () => request({ destino: TARGET_ID }), () => request({ transId: "  " }), () => request({ transId: "T-1", destino: "nope" })]) {
      const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
      requireRole.mockResolvedValueOnce(callCtx);

      expect((await POST(make(), paramsFor(OPERATION_ID))).status).toBe(400);
      expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
    }
  });

  it("RPC insufficient_privilege (42501) -> 403, validation (22023) -> 400 with message, not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "42501", message: "insufficient_privilege" } }));
    expect((await POST(request(GOOD), paramsFor(OPERATION_ID))).status).toBe(403);

    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "22023", message: "the target operation is closed" } }));
    const refused = await POST(request(GOOD), paramsFor(OPERATION_ID));
    expect(refused.status).toBe(400);
    expect((await refused.json()).error).toBe("the target operation is closed");

    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "deposit not found" } }));
    expect((await POST(request(GOOD), paramsFor(OPERATION_ID))).status).toBe(404);
  });

  it("moving: 200 with the RPC's answer and the RPC gets the operation, the TransID and the target", async () => {
    const { POST } = await import("./route");
    const answer = { moved: true, released: false, source_status: "awaiting_deposit", target_id: TARGET_ID, target_status: "ready_to_transfer" };
    const callCtx = ctx(ENABLED_PROFILE, { data: answer, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(GOOD), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toEqual({ ok: true, moved: true, released: false, sourceStatus: "awaiting_deposit", targetStatus: "ready_to_transfer" });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_mover_deposito", { p_operation_id: OPERATION_ID, p_trans_id: "10400000009977", p_destino: TARGET_ID });
  });

  it("releasing: no destino -> the RPC gets null", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: { moved: false, released: true, source_status: "awaiting_deposit" }, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ transId: "10400000009977" }), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(body).toEqual({ ok: true, moved: false, released: true, sourceStatus: "awaiting_deposit", targetStatus: null });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_mover_deposito", { p_operation_id: OPERATION_ID, p_trans_id: "10400000009977", p_destino: null });
  });
});
