// Route-level tests for POST /api/calculator/entries/{entryId}/rates.
// Covers admin-only role gating, entryId UUID validation, body validation
// (usdtBuyGyd / cupRate: finite numbers > 0, at least one present, nothing
// else), RPC error-code mapping and the happy-path payload + RPC arguments.

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
  return new Request(`http://local/api/calculator/entries/${ENTRY_ID}/rates`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

function paramsFor(entryId: string) {
  return { params: Promise.resolve({ entryId }) };
}

const CUP_ROW = {
  id: ENTRY_ID,
  account_id: "account-a",
  source: "completed_operation",
  status: "completed",
  operation_id: "op-1",
  entry_date: "2026-10-14",
  customer_name: "Raul",
  service: "CUP",
  amount: "106000",
  amount_currency: "CUP",
  facturado_gyd: "35333.33",
  invertido_gyd: "22833.33",
  retorno_gyd: "12500",
  cup_global_rate: "3",
  cup_rate: "960",
  usdt_buy_gyd: "206.8",
  usdt_sell_gyd: "215",
  rate_version_id: "rate-1",
  missing_inputs: null,
  delivery_mode: "proof_sent",
  voided_at: null,
  void_reason: null,
  completed_at: "2026-10-14T12:00:00Z",
  created_at: "2026-10-14T08:00:00Z",
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/calculator/entries/[entryId]/rates", () => {
  it("caller below admin -> role rejected by requireRole", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });

    const response = await POST(request({ cupRate: 960 }), paramsFor(ENTRY_ID));

    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(request({ cupRate: 960 }), paramsFor(ENTRY_ID));

    expect(response.status).toBe(401);
  });

  it("malformed entryId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    const response = await POST(request({ cupRate: 960 }), paramsFor("not-a-uuid"));

    expect(response.status).toBe(400);
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    const response = await POST(request(undefined, "{not-json"), paramsFor(ENTRY_ID));

    expect(response.status).toBe(400);
  });

  it.each([
    ["empty object", {}],
    ["null body", null],
    ["both rates null", { usdtBuyGyd: null, cupRate: null }],
    ["cupRate not a number", { cupRate: "960" }],
    ["usdtBuyGyd not a number", { usdtBuyGyd: "206" }],
    ["cupRate zero", { cupRate: 0 }],
    ["usdtBuyGyd negative", { usdtBuyGyd: -1 }],
    ["cupRate NaN", { cupRate: Number.NaN }],
    ["usdtBuyGyd Infinity", { usdtBuyGyd: Number.POSITIVE_INFINITY }],
    ["cupRate beyond the column limit", { cupRate: 1e9 }],
    ["valid usdtBuyGyd but invalid cupRate", { usdtBuyGyd: 206, cupRate: 0 }],
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

    const response = await POST(request({ cupRate: 960 }), paramsFor(ENTRY_ID));

    expect(response.status).toBe(404);
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "42501", message: "insufficient_privilege" } }),
    );

    const response = await POST(request({ cupRate: 960 }), paramsFor(ENTRY_ID));

    expect(response.status).toBe(403);
  });

  it("RPC refusal (22023: archived week, wrong service, ...) -> 400 with its message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "22023", message: "entry belongs to an archived week and cannot be corrected" } }),
    );

    const response = await POST(request({ cupRate: 960 }), paramsFor(ENTRY_ID));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("entry belongs to an archived week and cannot be corrected");
  });

  it("generic RPC error -> 500", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "XXYYY", message: "boom" } }),
    );

    const response = await POST(request({ cupRate: 960 }), paramsFor(ENTRY_ID));

    expect(response.status).toBe(500);
  });

  it("success with cupRate only -> 200 { entry }, RPC gets null for the other rate", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: CUP_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ cupRate: 960 }), paramsFor(ENTRY_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_corregir_tasas_entrada_calculadora", {
      p_entry_id: ENTRY_ID,
      p_usdt_buy_gyd: null,
      p_cup_rate: 960,
    });
    expect(body.entry).toMatchObject({
      id: ENTRY_ID,
      service: "CUP",
      facturadoGyd: 35333.33,
      invertidoGyd: 22833.33,
      retornoGyd: 12500,
    });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("success with both rates -> RPC gets both", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: CUP_ROW, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ usdtBuyGyd: 206.8, cupRate: 960 }), paramsFor(ENTRY_ID));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_corregir_tasas_entrada_calculadora", {
      p_entry_id: ENTRY_ID,
      p_usdt_buy_gyd: 206.8,
      p_cup_rate: 960,
    });
  });
});
