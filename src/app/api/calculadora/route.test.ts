// Route-level tests for GET/POST /api/calculadora. Covers auth gating,
// document-shape mapping (existing rows with and without the slice-1 USDT
// rate columns), and validation of the new optional rate fields. The
// reference calculation formulas live in web-calculator.ts and are not
// touched here.

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

function queryBuilder(result: { data: unknown; error: unknown }) {
  const builder = {
    select: vi.fn(() => builder),
    eq: vi.fn(() => builder),
    upsert: vi.fn(() => builder),
    order: vi.fn(() => builder),
    maybeSingle: vi.fn(() => Promise.resolve(result)),
    single: vi.fn(() => Promise.resolve(result)),
    // GET's chat-operations query is a plain multi-row select ending in
    // .order().order() with no terminal method — Supabase resolves that by
    // awaiting the builder itself, so the mock must be thenable too.
    then: (resolve: (value: { data: unknown; error: unknown }) => unknown) =>
      Promise.resolve(result).then(resolve),
  };
  return builder;
}

/** Routes `.from(table)` to a different canned result per table, mirroring
 * how GET now reads both remittance_calculator_documents and
 * remittance_calculator_entries in the same request. Tests that only care
 * about the document keep using the single-result `queryBuilder` helper via
 * `db(documentResult)`; tests exercising chatOperations pass both. */
function db(
  documentResult: { data: unknown; error: unknown },
  chatEntriesResult: { data: unknown; error: unknown } = { data: [], error: null },
) {
  const documentBuilder = queryBuilder(documentResult);
  const chatEntriesBuilder = queryBuilder(chatEntriesResult);
  return {
    from: vi.fn((table: string) =>
      table === "remittance_calculator_entries" ? chatEntriesBuilder : documentBuilder,
    ),
    documentBuilder,
    chatEntriesBuilder,
  };
}

const supabaseAdmin = vi.fn();
vi.mock("@/lib/flows/admin-client", () => ({ supabaseAdmin: () => supabaseAdmin() }));

const ACCOUNT = { accountId: "account-a", userId: "user-a", role: "agent" };

function jsonRequest(body: unknown) {
  return new Request("http://local/api/calculadora", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  getCurrentAccount.mockResolvedValue(ACCOUNT);
  canSendMessages.mockImplementation(() => true);
});

describe("GET /api/calculadora", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    getCurrentAccount.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await GET();

    expect(response.status).toBe(401);
  });

  it("viewer-role actor -> 403", async () => {
    const { GET } = await import("./route");
    canSendMessages.mockReturnValueOnce(false);

    const response = await GET();

    expect(response.status).toBe(403);
  });

  it("no document yet -> defaults tarifa to 3 and the new rates to null", async () => {
    const { GET } = await import("./route");
    const builder = queryBuilder({ data: null, error: null });
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await GET();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      rawText: "",
      periodo: "",
      tarifa: 3,
      compraUsdtGyd: null,
      ventaUsdtGyd: null,
      ventaUsdtCup: null,
      chatOperations: { entries: [], totals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 } },
    });
  });

  it("existing document predating this slice has null usdt rate columns", async () => {
    const { GET } = await import("./route");
    const database = db({
      data: {
        raw_text: "• Fran 50k CUP (235/980)",
        period_label: "SEMANA 1",
        cup_global_rate: "3",
        usdt_buy_gyd: null,
        usdt_sell_gyd: null,
        usdt_sell_cup: null,
      },
      error: null,
    });
    supabaseAdmin.mockReturnValue(database);

    const response = await GET();

    expect(await response.json()).toEqual({
      rawText: "• Fran 50k CUP (235/980)",
      periodo: "SEMANA 1",
      tarifa: 3,
      compraUsdtGyd: null,
      ventaUsdtGyd: null,
      ventaUsdtCup: null,
      chatOperations: { entries: [], totals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 } },
    });
  });

  it("converts Postgres numeric strings for all rate columns", async () => {
    const { GET } = await import("./route");
    const database = db({
      data: {
        raw_text: "",
        period_label: "",
        cup_global_rate: "3.5",
        usdt_buy_gyd: "235.5",
        usdt_sell_gyd: "260",
        usdt_sell_cup: "975.25",
      },
      error: null,
    });
    supabaseAdmin.mockReturnValue(database);

    const response = await GET();

    expect(await response.json()).toMatchObject({
      tarifa: 3.5,
      compraUsdtGyd: 235.5,
      ventaUsdtGyd: 260,
      ventaUsdtCup: 975.25,
      chatOperations: { entries: [], totals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 } },
    });
  });

  it("read failure maps to 500", async () => {
    const { GET } = await import("./route");
    const builder = queryBuilder({ data: null, error: { message: "boom" } });
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await GET();

    expect(response.status).toBe(500);
  });

  it("returns chat entries read-only and excludes verified_pending from totals", async () => {
    const { GET } = await import("./route");
    const database = db(
      {
        data: {
          raw_text: "",
          period_label: "",
          cup_global_rate: "3",
          usdt_buy_gyd: "240",
          usdt_sell_gyd: "260",
          usdt_sell_cup: null,
        },
        error: null,
      },
      {
        data: [
          {
            id: "entry-completed",
            operation_id: "op-completed",
            status: "completed",
            service: "ZELLE",
            customer_name: "Raúl",
            amount: "100",
            amount_currency: "USD",
            entry_date: "2026-09-12",
            facturado_gyd: "26000",
            invertido_gyd: "24000",
            retorno_gyd: "2000",
          },
          {
            id: "entry-pending",
            operation_id: "op-pending",
            status: "verified_pending",
            service: "CUP",
            customer_name: "Bladimir",
            amount: "30000",
            amount_currency: "CUP",
            entry_date: "2026-09-12",
            facturado_gyd: null,
            invertido_gyd: null,
            retorno_gyd: null,
          },
        ],
        error: null,
      },
    );
    supabaseAdmin.mockReturnValue(database);

    const response = await GET();
    const body = await response.json();

    expect(body.chatOperations.entries).toHaveLength(2);
    expect(body.chatOperations.entries[1].missingRates).toEqual(["usdtSellCup"]);
    expect(body.chatOperations.totals).toEqual({ facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, count: 1 });
  });
});

describe("POST /api/calculadora", () => {
  function okBuilder() {
    return queryBuilder({
      data: {
        raw_text: "text",
        period_label: "SEMANA 1",
        cup_global_rate: "3",
        usdt_buy_gyd: null,
        usdt_sell_gyd: null,
        usdt_sell_cup: null,
      },
      error: null,
    });
  }

  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    getCurrentAccount.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(jsonRequest({ rawText: "", periodo: "" }));

    expect(response.status).toBe(401);
  });

  it("viewer-role actor -> 403", async () => {
    const { POST } = await import("./route");
    canSendMessages.mockReturnValueOnce(false);

    const response = await POST(jsonRequest({ rawText: "", periodo: "" }));

    expect(response.status).toBe(403);
  });

  it("missing rawText/periodo -> 400", async () => {
    const { POST } = await import("./route");

    const response = await POST(jsonRequest({ tarifa: 3 }));

    expect(response.status).toBe(400);
  });

  it("non-positive tarifa -> 400", async () => {
    const { POST } = await import("./route");

    const response = await POST(jsonRequest({ rawText: "", periodo: "", tarifa: 0 }));

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "La tarifa CUP global debe ser mayor que cero" });
  });

  it.each([
    ["compraUsdtGyd", "Compra USDT (GYD)"],
    ["ventaUsdtGyd", "Venta USDT/Zelle (GYD)"],
    ["ventaUsdtCup", "Venta USDT (CUP)"],
  ])("non-positive %s -> 400 and the upsert never runs", async (key, label) => {
    const { POST } = await import("./route");
    const builder = okBuilder();
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await POST(jsonRequest({ rawText: "", periodo: "", tarifa: 3, [key]: 0 }));

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: `${label} debe ser mayor que cero` });
    expect(builder.upsert).not.toHaveBeenCalled();
  });

  it("rejects a non-finite optional rate", async () => {
    const { POST } = await import("./route");
    const builder = okBuilder();
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await POST(jsonRequest({ rawText: "", periodo: "", tarifa: 3, ventaUsdtGyd: "not-a-number" }));

    expect(response.status).toBe(400);
    expect(builder.upsert).not.toHaveBeenCalled();
  });

  it("omitted optional rates preserve existing columns for older clients", async () => {
    const { POST } = await import("./route");
    const builder = okBuilder();
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await POST(jsonRequest({ rawText: "text", periodo: "SEMANA 1", tarifa: 3 }));

    expect(response.status).toBe(200);
    const [payload] = builder.upsert.mock.calls as unknown as [Record<string, unknown>];
    expect(payload).not.toHaveProperty("usdt_buy_gyd");
    expect(payload).not.toHaveProperty("usdt_sell_gyd");
    expect(payload).not.toHaveProperty("usdt_sell_cup");
    expect(await response.json()).toEqual({
      rawText: "text",
      periodo: "SEMANA 1",
      tarifa: 3,
      compraUsdtGyd: null,
      ventaUsdtGyd: null,
      ventaUsdtCup: null,
    });
  });

  it("explicit null clears a previously saved rate", async () => {
    const { POST } = await import("./route");
    const builder = okBuilder();
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    await POST(jsonRequest({ rawText: "text", periodo: "SEMANA 1", tarifa: 3, compraUsdtGyd: null }));

    expect(builder.upsert).toHaveBeenCalledWith(
      expect.objectContaining({ usdt_buy_gyd: null }),
      { onConflict: "account_id" },
    );
  });

  it("blank optional rates are treated as null", async () => {
    const { POST } = await import("./route");
    const builder = okBuilder();
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await POST(jsonRequest({ rawText: "text", periodo: "SEMANA 1", tarifa: 3, ventaUsdtGyd: "" }));

    expect(response.status).toBe(200);
    expect(builder.upsert).toHaveBeenCalledWith(
      expect.objectContaining({ usdt_sell_gyd: null }),
      { onConflict: "account_id" },
    );
  });

  it("valid full payload persists all three new rate columns", async () => {
    const { POST } = await import("./route");
    const builder = queryBuilder({
      data: {
        raw_text: "text",
        period_label: "SEMANA 1",
        cup_global_rate: "3",
        usdt_buy_gyd: "235",
        usdt_sell_gyd: "260",
        usdt_sell_cup: "975",
      },
      error: null,
    });
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await POST(jsonRequest({
      rawText: "text",
      periodo: "SEMANA 1",
      tarifa: 3,
      compraUsdtGyd: 235,
      ventaUsdtGyd: 260,
      ventaUsdtCup: 975,
    }));

    expect(response.status).toBe(200);
    expect(builder.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        account_id: "account-a",
        raw_text: "text",
        period_label: "SEMANA 1",
        cup_global_rate: 3,
        usdt_buy_gyd: 235,
        usdt_sell_gyd: 260,
        usdt_sell_cup: 975,
        updated_by: "user-a",
      }),
      { onConflict: "account_id" },
    );
    expect(await response.json()).toEqual({
      rawText: "text",
      periodo: "SEMANA 1",
      tarifa: 3,
      compraUsdtGyd: 235,
      ventaUsdtGyd: 260,
      ventaUsdtCup: 975,
    });
  });

  it("save failure maps to 500", async () => {
    const { POST } = await import("./route");
    const builder = queryBuilder({ data: null, error: { message: "boom" } });
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await POST(jsonRequest({ rawText: "", periodo: "", tarifa: 3 }));

    expect(response.status).toBe(500);
  });
});
