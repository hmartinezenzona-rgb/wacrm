// Route-level tests for GET /api/remittance-operations/{operationId}/receipts.
// Covers auth gating, operationId validation, the beta-flag 404 (same gate
// as the sibling routes), RPC error-code mapping (42501/P0002/40001 from
// crm_comprobantes_de_operacion), and the happy-path mapped response shape.

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

function ctx(
  profileResult: { data: unknown; error: unknown },
  rpcResult: { data: unknown; error: unknown },
) {
  const rpc = vi.fn(() => Promise.resolve(rpcResult));
  const from = vi.fn(() => profileBuilder(profileResult));
  return {
    supabase: { from, rpc },
    userId: USER_ID,
    accountId: "account-a",
    role: "viewer" as const,
    account: { id: "account-a", name: "A" },
  };
}

function request() {
  return new Request(
    `http://local/api/remittance-operations/${OPERATION_ID}/receipts`,
  );
}

function paramsFor(operationId: string) {
  return { params: Promise.resolve({ operationId }) };
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/remittance-operations/[operationId]/receipts", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await GET(request(), paramsFor(OPERATION_ID));

    expect(response.status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await GET(request(), paramsFor("not-a-uuid"));

    expect(response.status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request(), paramsFor(OPERATION_ID));

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "42501", message: "insufficient_privilege" },
      }),
    );

    const response = await GET(request(), paramsFor(OPERATION_ID));

    expect(response.status).toBe(403);
  });

  it("RPC not found (P0002) -> 404", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "not found" } }),
    );

    const response = await GET(request(), paramsFor(OPERATION_ID));

    expect(response.status).toBe(404);
  });

  it("RPC serialization failure (40001) -> 409", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "40001", message: "could not serialize access" },
      }),
    );

    const response = await GET(request(), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(409);
    expect(body.error).toBe("Operation changed concurrently, retry");
  });

  it("beta flag enabled -> calls the RPC and returns the mapped read model", async () => {
    const { GET } = await import("./route");
    const rawPayload = {
      operation_id: OPERATION_ID,
      status: "deposit_verification",
      deal_id: "22222222-2222-2222-2222-222222222222",
      can_verify: true,
      objetivo: 25000,
      depositado: 25000,
      saldo: 0,
      moneda: "GYD",
      receipts: [
        {
          comp_id: "comp-1",
          message_id: "msg-1",
          media_url: "https://example.invalid/comp-1.jpg",
          received_at: "2026-09-14T10:00:00Z",
          declared_amount: 25000,
          declared_currency: "GYD",
          declared_ref: "TX-1",
          matched_deposit: null,
        },
      ],
      consumed_deposits: [],
    };
    const callCtx = ctx(ENABLED_PROFILE, { data: rawPayload, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request(), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith(
      "crm_comprobantes_de_operacion",
      { p_operation_id: OPERATION_ID },
    );
    expect(body.receipts.operationId).toBe(OPERATION_ID);
    expect(body.receipts.dealId).toBe("22222222-2222-2222-2222-222222222222");
    expect(body.receipts.canVerify).toBe(true);
    expect(body.receipts.receipts).toHaveLength(1);
    expect(body.receipts.receipts[0].compId).toBe("comp-1");
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });
});
