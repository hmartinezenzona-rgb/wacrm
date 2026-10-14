// POST /api/calculadora/entries: "Registrar" adds the Calculator text box's valid lines as manual operations (migration 228,
// crm_registrar_entradas_manuales). The RPC itself is guarded by supabase/staging/assertions/manual-entries.sql.

import { beforeEach, describe, expect, it, vi } from "vitest";

const getCurrentAccount = vi.fn();
const canSendMessages = vi.fn(() => true);

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ getCurrentAccount, toErrorResponse }));
vi.mock("@/lib/auth/roles", () => ({ canSendMessages }));

const LINE = {
  date: "2026-10-06", dayLabel: "Martes 6", customer: "Gerardo", service: "ZELLE", amount: 100,
  currency: "USD", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, rawLine: "• Gerardo 100 Zelle (240/260)",
};
const RPC_LINE = {
  date: "2026-10-06", day_label: "Martes 6", customer: "Gerardo", service: "ZELLE", amount: 100,
  currency: "USD", facturado_gyd: 26000, invertido_gyd: 24000, retorno_gyd: 2000, raw_line: "• Gerardo 100 Zelle (240/260)",
};
const CREATED_ROW = {
  id: "m1", account_id: "account-a", source: "manual", status: "completed", operation_id: null, entry_date: "2026-10-06",
  customer_name: "Gerardo", service: "ZELLE", amount: "100", amount_currency: "USD", facturado_gyd: "26000",
  invertido_gyd: "24000", retorno_gyd: "2000", missing_inputs: null, created_at: "2026-10-07T20:00:00Z", raw_line: "• Gerardo 100 Zelle (240/260)",
};

function account(rpcResult: { data: unknown; error: unknown } = { data: [CREATED_ROW], error: null }) {
  const supabase = { rpc: vi.fn(() => Promise.resolve(rpcResult)), from: vi.fn() };
  getCurrentAccount.mockResolvedValue({ accountId: "account-a", userId: "user-a", role: "agent", supabase });
  return supabase;
}

function post(body: unknown, raw?: string) {
  return new Request("http://local/api/calculadora/entries", { method: "POST", body: raw ?? JSON.stringify(body) });
}

beforeEach(() => {
  vi.clearAllMocks();
  canSendMessages.mockImplementation(() => true);
});

describe("POST /api/calculadora/entries", () => {
  it("adds the lines through crm_registrar_entradas_manuales and answers with the created entries as the table shows them", async () => {
    const { POST } = await import("./route");
    const supabase = account();

    const response = await POST(post({ lines: [LINE] }));

    expect(response.status).toBe(200);
    expect(supabase.rpc).toHaveBeenCalledTimes(1);
    expect(supabase.rpc).toHaveBeenCalledWith("crm_registrar_entradas_manuales", { p_account_id: "account-a", p_lineas: [RPC_LINE] });
    expect(await response.json()).toEqual({
      entries: [{
        id: "m1", operationId: null, source: "manual", status: "completed", service: "ZELLE", customerName: "Gerardo", amount: 100,
        amountCurrency: "USD", entryDate: "2026-10-06", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, missingRates: [], cupGlobalRate: null, cupRate: null, usdtBuyGyd: null, usdtSellGyd: null, costGyd: null, basisGyd: null, saleGyd: null,
        rawLine: "• Gerardo 100 Zelle (240/260)",
      }],
    });
  });

  it("runs on the caller's session client and writes nothing else", async () => {
    const { POST } = await import("./route");
    const supabase = account();
    await POST(post({ lines: [LINE] }));
    expect(supabase.from).not.toHaveBeenCalled();
  });

  it("a viewer is refused and the RPC never runs", async () => {
    const { POST } = await import("./route");
    const supabase = account();
    canSendMessages.mockImplementation(() => false);
    expect((await POST(post({ lines: [LINE] }))).status).toBe(403);
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it.each([
    ["invalid JSON", undefined, "{nope"],
    ["no lines key", {}, undefined],
    ["an empty list: there is nothing to register", { lines: [] }, undefined],
    ["a non-object line", { lines: ["x"] }, undefined],
    ["an unknown service", { lines: [{ ...LINE, service: "NOPE" }] }, undefined],
    ["a non-positive amount", { lines: [{ ...LINE, amount: 0 }] }, undefined],
    ["a negative figure", { lines: [{ ...LINE, facturadoGyd: -1 }] }, undefined],
    ["a figure that is not a number", { lines: [{ ...LINE, invertidoGyd: "24000" }] }, undefined],
    ["a bad date", { lines: [{ ...LINE, date: "6/10/2026" }] }, undefined],
    ["a valid line followed by a bad one", { lines: [LINE, { ...LINE, customer: "" }] }, undefined],
  ])("%s -> 400, the RPC never runs", async (_label, body, raw) => {
    const { POST } = await import("./route");
    const supabase = account();
    expect((await POST(post(body, raw))).status).toBe(400);
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it.each([
    ["42501", 403],
    ["22023", 400],
  ])("RPC error %s -> %i", async (code, status) => {
    const { POST } = await import("./route");
    account({ data: null, error: { code, message: "boom" } });
    expect((await POST(post({ lines: [LINE] }))).status).toBe(status);
  });

  it("an unexpected RPC error -> 500, never a silent success", async () => {
    const { POST } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    account({ data: null, error: { code: "XX000", message: "db down" } });
    expect((await POST(post({ lines: [LINE] }))).status).toBe(500);
  });

  it("an answer that is not a list of rows -> 500", async () => {
    const { POST } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    account({ data: { not: "a list" }, error: null });
    expect((await POST(post({ lines: [LINE] }))).status).toBe(500);
  });
});
