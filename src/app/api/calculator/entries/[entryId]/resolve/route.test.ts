// Route-level tests for POST /api/calculator/entries/{entryId}/resolve.
// Covers admin-only role gating, entryId UUID validation, reason-length
// validation, rates-shape/value validation (explicit null NOT allowed
// here, unlike the /rates route), RPC error-code mapping
// (P0002/42501/22023), and the happy-path mapped payload shape.

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
  return new Request(`http://local/api/calculator/entries/${ENTRY_ID}/resolve`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

function paramsFor(entryId: string) {
  return { params: Promise.resolve({ entryId }) };
}

const VALID_REASON = "Deposit confirmed by phone with the sender";
const VALID_RATES = { usdt_buy_gyd: 145, usdt_sell_gyd: 148 };

const RESOLVED_ROW = {
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
  facturado_gyd: "26000",
  invertido_gyd: "24000",
  retorno_gyd: "2000",
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

describe("POST /api/calculator/entries/[entryId]/resolve", () => {
  it("caller below admin -> role rejected by requireRole", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });

    const response = await POST(
      request({ rates: VALID_RATES, reason: VALID_REASON }),
      paramsFor(ENTRY_ID),
    );

    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(
      request({ rates: VALID_RATES, reason: VALID_REASON }),
      paramsFor(ENTRY_ID),
    );

    expect(response.status).toBe(401);
  });

  it("malformed entryId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    const response = await POST(
      request({ rates: VALID_RATES, reason: VALID_REASON }),
      paramsFor("not-a-uuid"),
    );

    expect(response.status).toBe(400);
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    const response = await POST(request(undefined, "{not-json"), paramsFor(ENTRY_ID));

    expect(response.status).toBe(400);
  });

  it.each([
    ["reason missing", {}],
    ["reason too short", { rates: VALID_RATES, reason: "abcd" }],
    ["reason blank after trim", { rates: VALID_RATES, reason: "    " }],
    ["reason not a string", { rates: VALID_RATES, reason: 12345 }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(body), paramsFor(ENTRY_ID));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it.each([
    ["rates missing", { reason: VALID_REASON }],
    ["rates empty object", { rates: {}, reason: VALID_REASON }],
    ["rates not an object", { rates: "nope", reason: VALID_REASON }],
    ["unknown rate key", { rates: { bogus_key: 1 }, reason: VALID_REASON }],
    ["explicit null rate value not allowed here", { rates: { usdt_buy_gyd: null }, reason: VALID_REASON }],
    ["non-positive rate value", { rates: { usdt_buy_gyd: 0 }, reason: VALID_REASON }],
    ["non-numeric rate value", { rates: { usdt_buy_gyd: "abc" }, reason: VALID_REASON }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(body), paramsFor(ENTRY_ID));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("accepts the cash sale rate key efectivo_usd_gyd and forwards it to the RPC", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: RESOLVED_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);
    const rates = { usdt_buy_gyd: 240, efectivo_usd_gyd: 290 };

    const response = await POST(request({ rates, reason: VALID_REASON }), paramsFor(ENTRY_ID));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_resolve_pending_entry", {
      p_entry_id: ENTRY_ID,
      p_rates: rates,
      p_reason: VALID_REASON,
    });
  });

  it("RPC entry not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "P0002", message: "entry not found" } }),
    );

    const response = await POST(
      request({ rates: VALID_RATES, reason: VALID_REASON }),
      paramsFor(ENTRY_ID),
    );

    expect(response.status).toBe(404);
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "42501", message: "insufficient_privilege" } }),
    );

    const response = await POST(
      request({ rates: VALID_RATES, reason: VALID_REASON }),
      paramsFor(ENTRY_ID),
    );

    expect(response.status).toBe(403);
  });

  it("RPC entry not pending / bad rate (22023) -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "22023", message: "entry is not pending" } }),
    );

    const response = await POST(
      request({ rates: VALID_RATES, reason: VALID_REASON }),
      paramsFor(ENTRY_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("entry is not pending");
  });

  it("success -> 200 { entry } and trims reason before calling the RPC", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: RESOLVED_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      request({ rates: VALID_RATES, reason: `  ${VALID_REASON}  ` }),
      paramsFor(ENTRY_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_resolve_pending_entry", {
      p_entry_id: ENTRY_ID,
      p_rates: VALID_RATES,
      p_reason: VALID_REASON,
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
      facturadoGyd: 26000,
      invertidoGyd: 24000,
      retornoGyd: 2000,
      missingRates: [],
      rateVersionId: "rate-1",
      deliveryMode: "proof_sent",
      voidedAt: null,
      voidReason: null,
      completedAt: "2026-09-12T12:00:00Z",
    });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });
});
