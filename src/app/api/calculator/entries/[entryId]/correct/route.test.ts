// Route-level tests for POST /api/calculator/entries/{entryId}/correct.
// Covers admin-only role gating, entryId UUID validation, body-shape/value
// validation (facturadoGyd/invertidoGyd must both be present, finite
// numbers >= 0), RPC error-code mapping (P0002/42501/22023), and the
// happy-path mapped payload shape.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const ENTRY_ID = "11111111-1111-1111-1111-111111111111";

function ctx(rpcResult: { data: unknown; error: unknown }) {
  const rpc = vi.fn(() => Promise.resolve(rpcResult));
  return {
    supabase: { rpc },
    userId: "user-a",
    accountId: "account-a",
    role: "admin" as const,
    account: { id: "account-a", name: "A" },
  };
}

function request(body?: unknown, rawBody?: string) {
  return new Request(`http://local/api/calculator/entries/${ENTRY_ID}/correct`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

function paramsFor(entryId: string) {
  return { params: Promise.resolve({ entryId }) };
}

const VALID_BODY = { facturadoGyd: 27000, invertidoGyd: 24000 };

const CORRECTED_ROW = {
  id: ENTRY_ID,
  account_id: "account-a",
  source: "completed_operation",
  status: "completed",
  operation_id: "op-1",
  entry_date: "2026-09-12",
  customer_name: "Raul",
  service: "ZELLE",
  amount: "100",
  amount_currency: "USD",
  facturado_gyd: "27000",
  invertido_gyd: "24000",
  retorno_gyd: "3000",
  cup_global_rate: null,
  cup_rate: null,
  usdt_buy_gyd: "145",
  usdt_sell_gyd: "148",
  rate_version_id: "rate-1",
  missing_inputs: [],
  delivery_mode: "proof_sent",
  voided_at: null,
  void_reason: null,
  completed_at: "2026-09-12T12:00:00Z",
  created_at: "2026-09-12T08:00:00Z",
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/calculator/entries/[entryId]/correct", () => {
  it("caller below admin -> role rejected by requireRole", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });

    const response = await POST(request(VALID_BODY), paramsFor(ENTRY_ID));

    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(request(VALID_BODY), paramsFor(ENTRY_ID));

    expect(response.status).toBe(401);
  });

  it("malformed entryId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    const response = await POST(request(VALID_BODY), paramsFor("not-a-uuid"));

    expect(response.status).toBe(400);
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    const response = await POST(request(undefined, "{not-json"), paramsFor(ENTRY_ID));

    expect(response.status).toBe(400);
  });

  it.each([
    ["facturadoGyd missing", { invertidoGyd: 24000 }],
    ["invertidoGyd missing", { facturadoGyd: 27000 }],
    ["facturadoGyd not a number", { facturadoGyd: "27000", invertidoGyd: 24000 }],
    ["invertidoGyd not a number", { facturadoGyd: 27000, invertidoGyd: "24000" }],
    ["facturadoGyd is NaN", { facturadoGyd: Number.NaN, invertidoGyd: 24000 }],
    ["facturadoGyd is Infinity", { facturadoGyd: Number.POSITIVE_INFINITY, invertidoGyd: 24000 }],
    ["facturadoGyd negative", { facturadoGyd: -1, invertidoGyd: 24000 }],
    ["invertidoGyd negative", { facturadoGyd: 27000, invertidoGyd: -1 }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(body), paramsFor(ENTRY_ID));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC entry not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "P0002", message: "entry not found" } }),
    );

    const response = await POST(request(VALID_BODY), paramsFor(ENTRY_ID));

    expect(response.status).toBe(404);
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "42501", message: "insufficient_privilege" } }),
    );

    const response = await POST(request(VALID_BODY), paramsFor(ENTRY_ID));

    expect(response.status).toBe(403);
  });

  it("RPC wrong entry status/source (22023) -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "22023", message: "entry cannot be corrected" } }),
    );

    const response = await POST(request(VALID_BODY), paramsFor(ENTRY_ID));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("entry cannot be corrected");
  });

  it("success -> 200 { entry } and calls the RPC with the right args", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: CORRECTED_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_BODY), paramsFor(ENTRY_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_corregir_entrada_calculadora", {
      p_entry_id: ENTRY_ID,
      p_facturado_gyd: 27000,
      p_invertido_gyd: 24000,
    });
    expect(body.entry).toEqual({
      id: ENTRY_ID,
      operationId: "op-1",
      source: "completed_operation",
      status: "completed",
      service: "ZELLE",
      customerName: "Raul",
      amount: 100,
      amountCurrency: "USD",
      entryDate: "2026-09-12",
      facturadoGyd: 27000,
      invertidoGyd: 24000,
      retornoGyd: 3000,
      missingRates: [],
      rateVersionId: "rate-1",
      deliveryMode: "proof_sent",
      voidedAt: null,
      voidReason: null,
      completedAt: "2026-09-12T12:00:00Z",
    });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("generic RPC error -> 500", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "XXYYY", message: "boom" } }),
    );

    const response = await POST(request(VALID_BODY), paramsFor(ENTRY_ID));

    expect(response.status).toBe(500);
  });
});
