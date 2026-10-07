// Route-level tests for POST /api/remittance-operations/{operationId}/service
// (crm_cambiar_servicio, migration 222): agent role, body validation, the beta flag,
// RPC error mapping (22023/P0002/42501 -> 400/404/403) and the happy path.

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

function request(body?: unknown, rawBody?: string) {
  return new Request(`http://local/api/remittance-operations/${OPERATION_ID}/service`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const paramsFor = (operationId: string) => ({ params: Promise.resolve({ operationId }) });

const OK_RPC = { data: { operation_id: OPERATION_ID, service: "clasica", changed: true }, error: null };

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/service", () => {
  it("requires the agent role: below agent -> 403, unauthenticated -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await POST(request({ servicio: "clasica" }), paramsFor(OPERATION_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("agent");

    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });
    expect((await POST(request({ servicio: "clasica" }), paramsFor(OPERATION_ID))).status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, OK_RPC));

    expect((await POST(request({ servicio: "clasica" }), paramsFor("nope"))).status).toBe(400);
  });

  it("without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, OK_RPC);
    requireRole.mockResolvedValueOnce(callCtx);

    expect((await POST(request({ servicio: "clasica" }), paramsFor(OPERATION_ID))).status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, OK_RPC));

    expect((await POST(request(undefined, "{nope"), paramsFor(OPERATION_ID))).status).toBe(400);
  });

  it.each([
    ["missing", {}],
    ["a number", { servicio: 3 }],
    ["not a service", { servicio: "bitcoin" }],
    ["empty", { servicio: "" }],
  ])("servicio %s -> 400 without calling the RPC", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, OK_RPC);
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

    expect((await POST(request({ servicio: "clasica" }), paramsFor(OPERATION_ID))).status).toBe(status);
  });

  it("an unknown RPC error -> 500", async () => {
    const { POST } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "XX000", message: "boom" } }));

    expect((await POST(request({ servicio: "clasica" }), paramsFor(OPERATION_ID))).status).toBe(500);
  });

  it.each(["cuban_card", "zelle", "clasica", "tropical", "efectivo_usd", "recarga", "combo", "visa", "saldo"])(
    "changes the service to %s: the RPC gets p_servicio and the summary comes back",
    async (servicio) => {
      const { POST } = await import("./route");
      const callCtx = ctx(ENABLED_PROFILE, {
        data: { operation_id: OPERATION_ID, service: servicio, changed: true },
        error: null,
      });
      requireRole.mockResolvedValueOnce(callCtx);

      const response = await POST(request({ servicio }), paramsFor(OPERATION_ID));

      expect(response.status).toBe(200);
      expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_cambiar_servicio", {
        p_operation_id: OPERATION_ID,
        p_servicio: servicio,
      });
      expect(await response.json()).toEqual({ ok: true, service: servicio, changed: true });
    },
  );
});
