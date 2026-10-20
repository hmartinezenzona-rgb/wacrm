// Route-level tests for POST /api/remittance-operations/{operationId}/split
// (crm_repartir_envio, migration 253): agent role, body validation, the beta flag,
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
const NEW_ID = "22222222-2222-2222-2222-222222222222";
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
  return new Request(`http://local/api/remittance-operations/${OPERATION_ID}/split`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const paramsFor = (operationId: string) => ({ params: Promise.resolve({ operationId }) });

const PARTS = [
  { service: "clasica", amountGyd: 18200 },
  { service: "recarga", amountGyd: 6200 },
];

const OK_RPC = {
  data: {
    grupo: OPERATION_ID,
    depositado: 24400,
    saldo: 0,
    partes: [
      { operation_id: OPERATION_ID, servicio: "clasica", monto_gyd: 18200, creada: false, status: "ready_to_transfer" },
      { operation_id: NEW_ID, servicio: "recarga", monto_gyd: 6200, creada: true, status: "ready_to_transfer" },
    ],
  },
  error: null,
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/split", () => {
  it("requires the agent role: below agent -> 403, unauthenticated -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await POST(request({ parts: PARTS }), paramsFor(OPERATION_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("agent");

    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });
    expect((await POST(request({ parts: PARTS }), paramsFor(OPERATION_ID))).status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, OK_RPC));

    expect((await POST(request({ parts: PARTS }), paramsFor("nope"))).status).toBe(400);
  });

  it("without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, OK_RPC);
    requireRole.mockResolvedValueOnce(callCtx);

    expect((await POST(request({ parts: PARTS }), paramsFor(OPERATION_ID))).status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, OK_RPC));

    expect((await POST(request(undefined, "{nope"), paramsFor(OPERATION_ID))).status).toBe(400);
  });

  it.each([
    ["missing", {}],
    ["not an array", { parts: "clasica" }],
    ["empty", { parts: [] }],
    ["a single part", { parts: [{ service: "clasica", amountGyd: 24400 }] }],
    ["a part that is not an object", { parts: [PARTS[0], 5] }],
    ["a part without a service", { parts: [PARTS[0], { amountGyd: 6200 }] }],
    ["a service that does not exist", { parts: [PARTS[0], { service: "bitcoin", amountGyd: 6200 }] }],
    ["an amount that is a string", { parts: [PARTS[0], { service: "recarga", amountGyd: "6200" }] }],
    ["an amount of zero", { parts: [PARTS[0], { service: "recarga", amountGyd: 0 }] }],
    ["a negative amount", { parts: [PARTS[0], { service: "recarga", amountGyd: -5 }] }],
    ["an amount that is not finite", { parts: [PARTS[0], { service: "recarga", amountGyd: null }] }],
  ])("parts %s -> 400 without calling the RPC", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, OK_RPC);
    requireRole.mockResolvedValueOnce(callCtx);

    expect((await POST(request(body), paramsFor(OPERATION_ID))).status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("22023 -> 400 carrying the RPC's message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "22023", message: "parts add up to 24000, the group holds 24400" } }),
    );

    const response = await POST(request({ parts: PARTS }), paramsFor(OPERATION_ID));

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "parts add up to 24000, the group holds 24400" });
  });

  it.each([
    ["42501", 403],
    ["P0002", 404],
  ])("RPC error %s -> %i", async (code, status) => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code, message: "boom" } }));

    expect((await POST(request({ parts: PARTS }), paramsFor(OPERATION_ID))).status).toBe(status);
  });

  it("an unknown RPC error -> 500", async () => {
    const { POST } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "XX000", message: "boom" } }));

    expect((await POST(request({ parts: PARTS }), paramsFor(OPERATION_ID))).status).toBe(500);
  });

  it("splits the deposit: the RPC gets the parts as servicio/monto_gyd and the summary comes back", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, OK_RPC);
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ parts: PARTS }), paramsFor(OPERATION_ID));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_repartir_envio", {
      p_operation_id: OPERATION_ID,
      p_partes: [
        { servicio: "clasica", monto_gyd: 18200 },
        { servicio: "recarga", monto_gyd: 6200 },
      ],
    });
    expect(await response.json()).toEqual({
      ok: true,
      group: OPERATION_ID,
      deposited: 24400,
      balance: 0,
      parts: [
        { operationId: OPERATION_ID, service: "clasica", amountGyd: 18200, created: false, status: "ready_to_transfer" },
        { operationId: NEW_ID, service: "recarga", amountGyd: 6200, created: true, status: "ready_to_transfer" },
      ],
    });
  });
});
