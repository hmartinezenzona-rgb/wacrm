// Route-level tests for GET /api/remittance-operations/{operationId}/usd-plan (crm_inventario_usd_operacion, migration 356):
// agent+ only, operationId validation, the beta flag, RPC error mapping, the camelCase mapping and the "unknown payload" failure.

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
  return { supabase: { from, rpc }, userId: "user-a", accountId: "account-a", role: "agent" as const };
}

const request = () => new Request(`http://local/api/remittance-operations/${OPERATION_ID}/usd-plan`);
const paramsFor = (operationId: string) => ({ params: Promise.resolve({ operationId }) });

beforeEach(() => vi.clearAllMocks());

describe("GET /api/remittance-operations/[operationId]/usd-plan", () => {
  it("requires the agent role: below agent -> 403, unauthenticated -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("agent");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(401);
  });

  it("malformed operationId -> 400 and the RPC is not called", async () => {
    const { GET } = await import("./route");
    const c = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await GET(request(), paramsFor("nope"))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("without the operations_panel flag -> 404 and the RPC is not called", async () => {
    const { GET } = await import("./route");
    const c = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(404);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("maps RPC errors: 42501 -> 403, P0002 -> 404; anything else -> 500", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "42501", message: "x" } }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(403);
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "x" } }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(404);
    vi.spyOn(console, "error").mockImplementation(() => {});
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "XX000", message: "boom" } }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(500);
  });

  it("calls crm_inventario_usd_operacion with the operation and returns the mapped plan, never cached", async () => {
    const { GET } = await import("./route");
    const c = ctx(ENABLED_PROFILE, {
      data: {
        state: "plan", operation_id: OPERATION_ID, estimate: true, cuba_month: "2026-11-01", blocked: true,
        services: [{ service: "TROPICAL", needed_usd: 400, planned_usd: 250, missing_usd: 150, blocked: true, invested_usdt: 238, lines: [], cards: [] }],
      },
      error: null,
    });
    requireRole.mockResolvedValueOnce(c);

    const response = await GET(request(), paramsFor(OPERATION_ID));

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_inventario_usd_operacion", { p_operation_id: OPERATION_ID });
    const body = await response.json();
    expect(body.usdPlan).toMatchObject({ state: "plan", blocked: true });
    expect(body.usdPlan.services[0]).toMatchObject({ service: "TROPICAL", missingUsd: 150, blocked: true });
  });

  it("an unknown payload -> 502", async () => {
    const { GET } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: { state: "weird" }, error: null }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(502);
  });
});
