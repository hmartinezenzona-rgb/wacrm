// Route-level tests for GET /api/calculator/entries. Covers role gating
// (viewer), the default void-exclusion, the ?includeVoid=true opt-in, the
// mapped payload shape, and the completed-only totals rule.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

function selectBuilder(result: { data: unknown; error: unknown }) {
  const builder = {
    select: vi.fn(() => builder),
    eq: vi.fn(() => builder),
    neq: vi.fn(() => builder),
    order: vi.fn(() => builder),
    // GET's list query ends in .order().order() (or .neq().order().order())
    // with no terminal method -- Supabase resolves that by awaiting the
    // builder itself, so the mock must be thenable too.
    then: (resolve: (value: { data: unknown; error: unknown }) => unknown) =>
      Promise.resolve(result).then(resolve),
  };
  return builder;
}

function ctx(result: { data: unknown; error: unknown }) {
  const builder = selectBuilder(result);
  const from = vi.fn(() => builder);
  return {
    supabase: { from },
    userId: "user-a",
    accountId: "account-a",
    role: "viewer" as const,
    account: { id: "account-a", name: "A" },
    builder,
  };
}

function request(query = "") {
  return new Request(`http://local/api/calculator/entries${query}`);
}

const COMPLETED_ROW = {
  id: "entry-completed",
  account_id: "account-a",
  source: "completed_operation",
  status: "completed",
  operation_id: "op-completed",
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
  usdt_buy_gyd: "240",
  usdt_sell_gyd: "260",
  rate_version_id: "rate-1",
  missing_inputs: [],
  delivery_mode: "proof_sent",
  voided_at: null,
  void_reason: null,
  completed_at: "2026-09-12T12:00:00Z",
  created_at: "2026-09-12T08:00:00Z",
};

const PENDING_ROW = {
  ...COMPLETED_ROW,
  id: "entry-pending",
  operation_id: "op-pending",
  status: "verified_pending",
  facturado_gyd: null,
  invertido_gyd: null,
  retorno_gyd: null,
  missing_inputs: ["usdtSellGyd"],
  completed_at: null,
};

const VOID_ROW = {
  ...COMPLETED_ROW,
  id: "entry-void",
  operation_id: "op-void",
  status: "void",
  voided_at: "2026-09-13T09:00:00Z",
  void_reason: "duplicate entry",
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/calculator/entries", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await GET(request());

    expect(response.status).toBe(401);
    expect(requireRole).toHaveBeenCalledWith("viewer");
  });

  it("scopes to the caller's account and completed_operation source only", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx({ data: [], error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    await GET(request());

    expect(callCtx.builder.eq).toHaveBeenCalledWith("account_id", "account-a");
    expect(callCtx.builder.eq).toHaveBeenCalledWith("source", "completed_operation");
    expect(callCtx.builder.order).toHaveBeenCalledWith("entry_date", { ascending: false });
    expect(callCtx.builder.order).toHaveBeenCalledWith("created_at", { ascending: false });
  });

  it("excludes void rows by default", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx({ data: [COMPLETED_ROW, PENDING_ROW], error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    await GET(request());

    expect(callCtx.builder.neq).toHaveBeenCalledWith("status", "void");
  });

  it("includeVoid=true skips the void exclusion filter", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx({ data: [COMPLETED_ROW, VOID_ROW], error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    await GET(request("?includeVoid=true"));

    expect(callCtx.builder.neq).not.toHaveBeenCalled();
  });

  it("maps entries and totals, excluding pending and void from totals", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx({ data: [COMPLETED_ROW, PENDING_ROW, VOID_ROW], error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request("?includeVoid=true"));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.entries).toHaveLength(3);
    expect(body.entries[0]).toEqual({
      id: "entry-completed",
      operationId: "op-completed",
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
    expect(body.entries[1].missingRates).toEqual(["usdtSellGyd"]);
    expect(body.entries[2].voidReason).toBe("duplicate entry");
    expect(body.totals).toEqual({
      facturadoGyd: 26000,
      invertidoGyd: 24000,
      retornoGyd: 2000,
      count: 1,
    });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("empty ledger -> empty entries and all-zero totals", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: [], error: null }));

    const response = await GET(request());
    const body = await response.json();

    expect(body).toEqual({
      entries: [],
      totals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 },
    });
  });

  it("read failure maps to 500", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { message: "boom" } }));

    const response = await GET(request());

    expect(response.status).toBe(500);
  });
});
