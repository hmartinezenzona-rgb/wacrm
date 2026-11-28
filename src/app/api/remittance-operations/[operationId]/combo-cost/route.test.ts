// Route-level tests for POST /api/remittance-operations/{operationId}/combo-cost
// (crm_set_combo_costo, migration 208): admin-only, body validation, the beta
// flag, RPC error mapping (22023/P0002/42501 -> 400/404/403) and the happy path.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

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
  return { supabase: { from, rpc }, userId: "user-a", accountId: "account-a", role: "admin" as const };
}

function request(body?: unknown, rawBody?: string) {
  return new Request(`http://local/api/remittance-operations/${OPERATION_ID}/combo-cost`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const paramsFor = (operationId: string) => ({ params: Promise.resolve({ operationId }) });

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/combo-cost", () => {
  it("requires the admin role: below admin -> 403, unauthenticated -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await POST(request({ costGyd: 100 }), paramsFor(OPERATION_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");

    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });
    expect((await POST(request({ costGyd: 100 }), paramsFor(OPERATION_ID))).status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    expect((await POST(request({ costGyd: 100 }), paramsFor("nope"))).status).toBe(400);
  });

  it("without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    expect((await POST(request({ costGyd: 100 }), paramsFor(OPERATION_ID))).status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    expect((await POST(request(undefined, "{nope"), paramsFor(OPERATION_ID))).status).toBe(400);
  });

  it.each([
    ["missing", {}],
    ["a string", { costGyd: "100" }],
    ["negative", { costGyd: -1 }],
    ["at the 1e9 ceiling", { costGyd: 1e9 }],
  ])("costGyd %s -> 400 without calling the RPC", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    expect((await POST(request(body), paramsFor(OPERATION_ID))).status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it.each([
    ["42501", 403],
    ["22023", 400],
    ["P0002", 404],
  ])("RPC error %s -> %i", async (code, status) => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code, message: "boom" } }));

    expect((await POST(request({ costGyd: 100 }), paramsFor(OPERATION_ID))).status).toBe(status);
  });

  it("an unknown RPC error -> 500", async () => {
    const { POST } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "XX000", message: "boom" } }));

    expect((await POST(request({ costGyd: 100 }), paramsFor(OPERATION_ID))).status).toBe(500);
  });

  it("saves a cost: RPC gets p_costo_gyd and the saved value comes back", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: { combo_costo_gyd: 18000.5 }, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ costGyd: 18000.5 }), paramsFor(OPERATION_ID));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_set_combo_costo", {
      p_operation_id: OPERATION_ID,
      p_costo_gyd: 18000.5,
    });
    expect(await response.json()).toEqual({ ok: true, costGyd: 18000.5 });
  });

  it("accepts zero, and null clears the cost", async () => {
    const { POST } = await import("./route");
    const zero = ctx(ENABLED_PROFILE, { data: { combo_costo_gyd: 0 }, error: null });
    requireRole.mockResolvedValueOnce(zero);
    expect((await POST(request({ costGyd: 0 }), paramsFor(OPERATION_ID))).status).toBe(200);
    expect(zero.supabase.rpc).toHaveBeenCalledWith("crm_set_combo_costo", { p_operation_id: OPERATION_ID, p_costo_gyd: 0 });

    const cleared = ctx(ENABLED_PROFILE, { data: { combo_costo_gyd: null }, error: null });
    requireRole.mockResolvedValueOnce(cleared);
    const response = await POST(request({ costGyd: null }), paramsFor(OPERATION_ID));
    expect(response.status).toBe(200);
    expect(cleared.supabase.rpc).toHaveBeenCalledWith("crm_set_combo_costo", { p_operation_id: OPERATION_ID, p_costo_gyd: null });
    expect(await response.json()).toEqual({ ok: true, costGyd: null });
  });
});
