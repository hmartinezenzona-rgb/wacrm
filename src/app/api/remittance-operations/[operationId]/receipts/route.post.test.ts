// Route-level tests for POST /api/remittance-operations/{operationId}/receipts  { wamid, ref?, monto? } (crm_adjuntar_comprobante, migration 382):
// auth gating, operationId and body validation, the beta-flag 404, RPC error mapping (42501/22023/P0002) and the happy-path response.

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
  return new Request(`http://local/api/remittance-operations/${OPERATION_ID}/receipts`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const paramsFor = (operationId: string) => ({ params: Promise.resolve({ operationId }) });

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/receipts", () => {
  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    expect((await POST(request({ wamid: "wamid.X" }), paramsFor(OPERATION_ID))).status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    expect((await POST(request({ wamid: "wamid.X" }), paramsFor("not-a-uuid"))).status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ wamid: "wamid.X" }), paramsFor(OPERATION_ID));

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON, a missing wamid, a non-string ref and a non-number monto -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    for (const make of [() => request(undefined, "{not-json"), () => request({}), () => request({ wamid: " " }), () => request({ wamid: "w", ref: 5 }), () => request({ wamid: "w", monto: "mucho" })]) {
      const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
      requireRole.mockResolvedValueOnce(callCtx);

      expect((await POST(make(), paramsFor(OPERATION_ID))).status).toBe(400);
      expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
    }
  });

  it("RPC insufficient_privilege (42501) -> 403, validation (22023) -> 400 with message, not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "42501", message: "insufficient_privilege" } }));
    expect((await POST(request({ wamid: "wamid.X" }), paramsFor(OPERATION_ID))).status).toBe(403);

    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "22023", message: "amount must be positive" } }));
    const refused = await POST(request({ wamid: "wamid.X" }), paramsFor(OPERATION_ID));
    expect(refused.status).toBe(400);
    expect((await refused.json()).error).toBe("amount must be positive");

    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "operation not found" } }));
    expect((await POST(request({ wamid: "wamid.X" }), paramsFor(OPERATION_ID))).status).toBe(404);
  });

  it("an image that is already a receipt of the operation -> 409 receipt_already_attached, not the raw server sentence", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "22023", message: "this image is already a receipt of the operation" } }));

    const response = await POST(request({ wamid: "wamid.X" }), paramsFor(OPERATION_ID));

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "receipt_already_attached" });
  });

  it("success -> 200 { ok, compId, reference, amount, prefilled } and the RPC gets the image, the typed reference and amount", async () => {
    const { POST } = await import("./route");
    const answer = { comp_id: "COMP-abc1234", reference: "10400000009977", amount: 13000, prefilled: false };
    const callCtx = ctx(ENABLED_PROFILE, { data: answer, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ wamid: "wamid.X", ref: "10400000009977", monto: 13000 }), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toEqual({ ok: true, compId: "COMP-abc1234", reference: "10400000009977", amount: 13000, prefilled: false });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_adjuntar_comprobante", {
      p_operation_id: OPERATION_ID,
      p_wamid: "wamid.X",
      p_ref: "10400000009977",
      p_monto: 13000,
    });
  });

  it("only the image: the reference and the amount go as null so the reading fills them", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: { comp_id: "COMP-1", reference: "104", amount: 13000, prefilled: true }, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const body = await (await POST(request({ wamid: "wamid.X" }), paramsFor(OPERATION_ID))).json();

    expect(body.prefilled).toBe(true);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_adjuntar_comprobante", { p_operation_id: OPERATION_ID, p_wamid: "wamid.X", p_ref: null, p_monto: null });
  });
});
