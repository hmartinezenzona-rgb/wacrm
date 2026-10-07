// Route-level tests for GET/POST /api/calculator/rates. Covers role
// gating (viewer for GET, admin for POST), the "no rates set yet" null
// case, unknown-rate-key rejection, expectedVersionId UUID validation, RPC
// error-code mapping (42501/22023/40001), and the happy-path payload shape.

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
    order: vi.fn(() => builder),
    limit: vi.fn(() => builder),
    maybeSingle: vi.fn(() => Promise.resolve(result)),
  };
  return builder;
}

function ctx(
  selectResult: { data: unknown; error: unknown },
  rpcResult: { data: unknown; error: unknown } = { data: null, error: null },
) {
  const builder = selectBuilder(selectResult);
  const rpc = vi.fn(() => Promise.resolve(rpcResult));
  const from = vi.fn(() => builder);
  return {
    supabase: { from, rpc },
    userId: "user-a",
    accountId: "account-a",
    role: "admin" as const,
    account: { id: "account-a", name: "A" },
    builder,
  };
}

function jsonRequest(body?: unknown, rawBody?: string) {
  return new Request("http://local/api/calculator/rates", {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const RATE_ROW = {
  id: "rate-1",
  account_id: "account-a",
  cup_global_rate: "3.25",
  usdt_buy_gyd: "145",
  usdt_sell_gyd: "148",
  usdt_sell_cup: "1.05",
  efectivo_usd_gyd: "290",
  recarga_costo_usdt: "4.5",
  saldo_costo_usdt: "1.25",
  zelle_sell_gyd: "260",
  zelle_sell_gyd_1000: "250",
  zelle_sell_gyd_2000: "245",
  set_by: "user-a",
  effective_at: "2026-09-10T08:00:00Z",
};

const MAPPED_RATES = {
  id: "rate-1",
  cupGlobalRate: 3.25,
  usdtBuyGyd: 145,
  usdtSellGyd: 148,
  usdtSellCup: 1.05,
  efectivoUsdGyd: 290,
  recargaCostoUsdt: 4.5,
  saldoCostoUsdt: 1.25,
  zelleSellGyd: 260,
  zelleSellGyd1000: 250,
  zelleSellGyd2000: 245,
  effectiveAt: "2026-09-10T08:00:00Z",
  setBy: "user-a",
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/calculator/rates", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await GET();

    expect(response.status).toBe(401);
    expect(requireRole).toHaveBeenCalledWith("viewer");
  });

  it("account has never set rates -> { rates: null }, not zeros", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    const response = await GET();
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toEqual({ rates: null });
  });

  it("returns the newest rate version, mapped to camelCase", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx({ data: RATE_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET();
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toEqual({ rates: MAPPED_RATES });
    expect(callCtx.builder.order).toHaveBeenCalledWith("effective_at", { ascending: false });
    expect(callCtx.builder.order).toHaveBeenCalledWith("id", { ascending: false });
    expect(callCtx.builder.limit).toHaveBeenCalledWith(1);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("read failure maps to 500", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { message: "boom" } }));

    const response = await GET();

    expect(response.status).toBe(500);
  });
});

describe("POST /api/calculator/rates", () => {
  it("caller below admin -> role rejected by requireRole", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });

    const response = await POST(jsonRequest({ rates: { cup_global_rate: 3 } }));

    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    const response = await POST(jsonRequest(undefined, "{not-json"));

    expect(response.status).toBe(400);
  });

  it.each([
    ["rates missing", {}],
    ["rates empty object", { rates: {} }],
    ["rates not an object", { rates: "nope" }],
    ["rates an array", { rates: [1, 2] }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(jsonRequest(body));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("unknown rate key -> 400 before calling the RPC", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(jsonRequest({ rates: { cup_global_rate: 3, bogus_key: 1 } }));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("expectedVersionId not a UUID -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      jsonRequest({ rates: { cup_global_rate: 3 }, expectedVersionId: "not-a-uuid" }),
    );

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(
        { data: null, error: null },
        { data: null, error: { code: "42501", message: "insufficient_privilege" } },
      ),
    );

    const response = await POST(jsonRequest({ rates: { cup_global_rate: 3 } }));

    expect(response.status).toBe(403);
  });

  it("RPC bad rate value (22023) -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(
        { data: null, error: null },
        { data: null, error: { code: "22023", message: "rate must be > 0" } },
      ),
    );

    const response = await POST(jsonRequest({ rates: { cup_global_rate: -1 } }));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("rate must be > 0");
  });

  it("RPC stale expectedVersionId (40001) -> 409", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(
        { data: null, error: null },
        { data: null, error: { code: "40001", message: "stale version" } },
      ),
    );

    const response = await POST(
      jsonRequest({
        rates: { cup_global_rate: 3 },
        expectedVersionId: "11111111-1111-1111-1111-111111111111",
      }),
    );

    expect(response.status).toBe(409);
  });

  it("success -> 200 { rates } and calls the RPC with the caller's account + exact rates object", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null }, { data: RATE_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      jsonRequest({
        rates: { cup_global_rate: 3.25, usdt_sell_cup: null },
        expectedVersionId: "11111111-1111-1111-1111-111111111111",
      }),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_set_calculator_rates", {
      p_account_id: "account-a",
      p_rates: { cup_global_rate: 3.25, usdt_sell_cup: null },
      p_expected_version_id: "11111111-1111-1111-1111-111111111111",
    });
    expect(body).toEqual({ rates: MAPPED_RATES });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("accepts and forwards efectivo_usd_gyd (number or null) to the RPC", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null }, { data: RATE_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(jsonRequest({ rates: { efectivo_usd_gyd: 295 } }));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_set_calculator_rates", {
      p_account_id: "account-a",
      p_rates: { efectivo_usd_gyd: 295 },
      p_expected_version_id: null,
    });
    expect(body.rates.efectivoUsdGyd).toBe(290);
  });

  it("accepts and forwards recarga_costo_usdt to the RPC", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null }, { data: RATE_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(jsonRequest({ rates: { recarga_costo_usdt: 4.5 } }));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_set_calculator_rates", {
      p_account_id: "account-a",
      p_rates: { recarga_costo_usdt: 4.5 },
      p_expected_version_id: null,
    });
  });

  it("accepts and forwards saldo_costo_usdt to the RPC (migration 223)", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null }, { data: RATE_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(jsonRequest({ rates: { saldo_costo_usdt: 1.25 } }));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_set_calculator_rates", {
      p_account_id: "account-a",
      p_rates: { saldo_costo_usdt: 1.25 },
      p_expected_version_id: null,
    });
    expect((await response.json()).rates.saldoCostoUsdt).toBe(1.25);
  });

  it("accepts and forwards the three Zelle tier prices to the RPC and returns them (migration 216)", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null }, { data: RATE_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      jsonRequest({ rates: { zelle_sell_gyd: 265, zelle_sell_gyd_1000: 255, zelle_sell_gyd_2000: null } }),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_set_calculator_rates", {
      p_account_id: "account-a",
      p_rates: { zelle_sell_gyd: 265, zelle_sell_gyd_1000: 255, zelle_sell_gyd_2000: null },
      p_expected_version_id: null,
    });
    expect(body.rates).toMatchObject({ zelleSellGyd: 260, zelleSellGyd1000: 250, zelleSellGyd2000: 245 });
  });

  it("GET selects the three Zelle price columns", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx({ data: RATE_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    await GET();

    const columns = (callCtx.builder.select.mock.calls as unknown as string[][])[0]![0]!;
    expect(columns).toContain("zelle_sell_gyd,");
    expect(columns).toContain("zelle_sell_gyd_1000");
    expect(columns).toContain("zelle_sell_gyd_2000");
  });

  it("an out-of-range efectivo_usd_gyd rejected by the RPC is not swallowed (no 200)", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }, { data: null, error: { message: "boom" } }));

    const response = await POST(jsonRequest({ rates: { efectivo_usd_gyd: -1 } }));

    expect(response.status).toBeGreaterThanOrEqual(400);
  });

  it("omitted expectedVersionId defaults to null", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null }, { data: RATE_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    await POST(jsonRequest({ rates: { cup_global_rate: 3.25 } }));

    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_set_calculator_rates", {
      p_account_id: "account-a",
      p_rates: { cup_global_rate: 3.25 },
      p_expected_version_id: null,
    });
  });
});
