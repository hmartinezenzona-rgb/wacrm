// Route-level tests for GET /api/remittance-operations. Covers auth
// gating, conversationId validation, the beta-flag 404 (design decision
// 8: gate is UI + API, never just the UI), the 42501 -> 403 mapping from
// the RPC's own authorization, and the happy-path read-model shape.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const USER_ID = "user-a";

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
  return { supabase: { from, rpc }, userId: USER_ID, accountId: "account-a", role: "viewer" as const, account: { id: "account-a", name: "A" } };
}

function request(conversationId?: string) {
  const url = conversationId
    ? `http://local/api/remittance-operations?conversationId=${conversationId}`
    : "http://local/api/remittance-operations";
  return new Request(url);
}

const CONVERSATION_ID = "11111111-1111-1111-1111-111111111111";

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/remittance-operations", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await GET(request(CONVERSATION_ID));

    expect(response.status).toBe(401);
  });

  it("missing conversationId -> 400", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: { beta_features: ["operations_panel"] }, error: null }, { data: [], error: null }));

    const response = await GET(request());

    expect(response.status).toBe(400);
  });

  it("malformed conversationId -> 400", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: { beta_features: ["operations_panel"] }, error: null }, { data: [], error: null }));

    const response = await GET(request("not-a-uuid"));

    expect(response.status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx({ data: { beta_features: [] }, error: null }, { data: [], error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request(CONVERSATION_ID));

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(
        { data: { beta_features: ["operations_panel"] }, error: null },
        { data: null, error: { code: "42501", message: "insufficient_privilege" } },
      ),
    );

    const response = await GET(request(CONVERSATION_ID));

    expect(response.status).toBe(403);
  });

  it("beta flag enabled -> calls the RPC and returns the mapped read model", async () => {
    const { GET } = await import("./route");
    const rows = [
      {
        resolver_resultado: "unica",
        resolver_operation_id: "op-1",
        resolver_candidatas: 1,
        operation_id: "op-1",
        operation_status: "ready_to_transfer",
        operation_service_type: "remesa",
        operation_source_currency: "GYD",
        operation_destination_currency: null,
        operation_delivery_method: null,
        operation_deposit_method: null,
        operation_quoted_source_amount: 5000,
        operation_quoted_destination_amount: null,
        operation_admin_locked_fields: {},
        operation_created_at: "2026-09-14T00:00:00Z",
        operation_completed_at: null,
        beneficiary_id: "ben-1",
        beneficiary_type: "cuban_card",
        beneficiary_name: "Solo Beneficiario",
        beneficiary_card_number: "1111222233334444",
        beneficiary_phone: null,
        beneficiary_zelle_account: null,
        beneficiary_delivery_method: null,
        beneficiary_amount: null,
        beneficiary_currency: null,
        beneficiary_position: 1,
      },
    ];
    const callCtx = ctx({ data: { beta_features: ["operations_panel"] }, error: null }, { data: rows, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request(CONVERSATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_operaciones_de_conversacion", {
      p_conversation_id: CONVERSATION_ID,
    });
    expect(body.resolverState).toBe("unica");
    expect(body.operations).toHaveLength(1);
    expect(body.operations[0].beneficiaries[0].cardNumberMasked).toBe("1111****4444");
    // Raw card number must never leave the server.
    expect(JSON.stringify(body)).not.toContain("1111222233334444");
  });
});
