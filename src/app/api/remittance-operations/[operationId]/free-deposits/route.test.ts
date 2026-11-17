// Route-level tests for GET /api/remittance-operations/{operationId}/free-deposits (crm_depositos_sin_dueno, migration 380): auth gating,
// operationId validation, the beta-flag 404, RPC error mapping (42501/P0002) and the happy-path mapping to camelCase.

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

const request = () => new Request(`http://local/api/remittance-operations/${OPERATION_ID}/free-deposits`);
const paramsFor = (operationId: string) => ({ params: Promise.resolve({ operationId }) });

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/remittance-operations/[operationId]/free-deposits", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: [], error: null }));

    expect((await GET(request(), paramsFor("not-a-uuid"))).status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: [], error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request(), paramsFor(OPERATION_ID));

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC insufficient_privilege (42501) -> 403 and not found (P0002) -> 404", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "42501", message: "insufficient_privilege" } }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(403);

    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "operation not found" } }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(404);
  });

  it("success -> 200 { deposits } in camelCase, calling the RPC with the operation id", async () => {
    const { GET } = await import("./route");
    const rows = [
      { trans_id: "T-1", amount: 13000, currency: "GYD", received_at: "2026-11-17T14:18:14Z", holder: "Pagador Uno" },
      { trans_id: "T-2", amount: 5000, currency: "GYD", received_at: "2026-11-16T20:25:00Z", holder: null },
    ];
    const callCtx = ctx(ENABLED_PROFILE, { data: rows, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request(), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.deposits).toEqual([
      { transId: "T-1", amount: 13000, currency: "GYD", receivedAt: "2026-11-17T14:18:14Z", holder: "Pagador Uno" },
      { transId: "T-2", amount: 5000, currency: "GYD", receivedAt: "2026-11-16T20:25:00Z", holder: null },
    ]);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_depositos_sin_dueno", { p_operation_id: OPERATION_ID });
  });

  it("an empty answer is an empty list", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const body = await (await GET(request(), paramsFor(OPERATION_ID))).json();

    expect(body.deposits).toEqual([]);
  });
});
