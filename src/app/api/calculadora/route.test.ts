// Route-level tests for GET/POST /api/calculadora. Covers auth gating,
// document-shape mapping (raw_text/period_label only -- the four global
// rates now live in calculator_rate_versions, read via mapRateVersion), and
// the chat-operations read side (missingRates sourced straight from the
// stored missing_inputs column, void entries excluded). The reference
// calculation formulas live in web-calculator.ts and are not touched here.

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
    neq: vi.fn(() => builder),
    upsert: vi.fn(() => builder),
    order: vi.fn(() => builder),
    limit: vi.fn(() => builder),
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

/** Routes `.from(table)` to a different canned result per table: GET now
 * reads remittance_calculator_documents (raw_text/period_label only),
 * calculator_rate_versions (the newest rate row), and
 * remittance_calculator_entries (chat operations) in the same request. */
function db(
  documentResult: { data: unknown; error: unknown } = { data: null, error: null },
  rateResult: { data: unknown; error: unknown } = { data: null, error: null },
  chatEntriesResult: { data: unknown; error: unknown } = { data: [], error: null },
) {
  const documentBuilder = queryBuilder(documentResult);
  const rateBuilder = queryBuilder(rateResult);
  const chatEntriesBuilder = queryBuilder(chatEntriesResult);
  return {
    from: vi.fn((table: string) => {
      if (table === "remittance_calculator_entries") return chatEntriesBuilder;
      if (table === "calculator_rate_versions") return rateBuilder;
      return documentBuilder;
    }),
    documentBuilder,
    rateBuilder,
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

  it("no document and no rate version yet -> empty text, null rates (no default)", async () => {
    const { GET } = await import("./route");
    supabaseAdmin.mockReturnValue(db());

    const response = await GET();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      rawText: "",
      periodo: "",
      tarifa: null,
      compraUsdtGyd: null,
      ventaUsdtGyd: null,
      ventaUsdtCup: null,
      chatOperations: { entries: [], totals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 } },
    });
  });

  it("existing document text but no rate version yet -> text hydrates, rates stay null", async () => {
    const { GET } = await import("./route");
    const database = db({
      data: { raw_text: "• Fran 50k CUP (235/980)", period_label: "SEMANA 1" },
      error: null,
    });
    supabaseAdmin.mockReturnValue(database);

    const response = await GET();

    expect(await response.json()).toEqual({
      rawText: "• Fran 50k CUP (235/980)",
      periodo: "SEMANA 1",
      tarifa: null,
      compraUsdtGyd: null,
      ventaUsdtGyd: null,
      ventaUsdtCup: null,
      chatOperations: { entries: [], totals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 } },
    });
  });

  it("reads the newest calculator_rate_versions row and converts numeric strings", async () => {
    const { GET } = await import("./route");
    const database = db(
      { data: { raw_text: "", period_label: "" }, error: null },
      {
        data: {
          id: "rate-1",
          account_id: "account-a",
          cup_global_rate: "3.5",
          usdt_buy_gyd: "235.5",
          usdt_sell_gyd: "260",
          usdt_sell_cup: "975.25",
          set_by: "user-a",
          effective_at: "2026-09-10T00:00:00Z",
        },
        error: null,
      },
    );
    supabaseAdmin.mockReturnValue(database);

    const response = await GET();

    expect(await response.json()).toMatchObject({
      tarifa: 3.5,
      compraUsdtGyd: 235.5,
      ventaUsdtGyd: 260,
      ventaUsdtCup: 975.25,
    });
    expect(database.rateBuilder.eq).toHaveBeenCalledWith("account_id", "account-a");
    expect(database.rateBuilder.order).toHaveBeenCalledWith("effective_at", { ascending: false });
    expect(database.rateBuilder.order).toHaveBeenCalledWith("id", { ascending: false });
    expect(database.rateBuilder.limit).toHaveBeenCalledWith(1);
  });

  it("a rate version with unset (null) columns stays null, never a fabricated default", async () => {
    const { GET } = await import("./route");
    const database = db(
      { data: { raw_text: "", period_label: "" }, error: null },
      {
        data: {
          id: "rate-1",
          account_id: "account-a",
          cup_global_rate: null,
          usdt_buy_gyd: null,
          usdt_sell_gyd: null,
          usdt_sell_cup: null,
          set_by: "user-a",
          effective_at: "2026-09-10T00:00:00Z",
        },
        error: null,
      },
    );
    supabaseAdmin.mockReturnValue(database);

    const response = await GET();

    expect(await response.json()).toMatchObject({
      tarifa: null,
      compraUsdtGyd: null,
      ventaUsdtGyd: null,
      ventaUsdtCup: null,
    });
  });

  it("document read failure maps to 500", async () => {
    const { GET } = await import("./route");
    supabaseAdmin.mockReturnValue(db({ data: null, error: { message: "boom" } }));

    const response = await GET();

    expect(response.status).toBe(500);
  });

  it("rate version read failure maps to 500", async () => {
    const { GET } = await import("./route");
    supabaseAdmin.mockReturnValue(
      db({ data: null, error: null }, { data: null, error: { message: "boom" } }),
    );

    const response = await GET();

    expect(response.status).toBe(500);
  });

  it("chat entries read failure maps to 500", async () => {
    const { GET } = await import("./route");
    supabaseAdmin.mockReturnValue(
      db({ data: null, error: null }, { data: null, error: null }, { data: null, error: { message: "boom" } }),
    );

    const response = await GET();

    expect(response.status).toBe(500);
  });

  it("returns chat entries read-only, sourcing missingRates from missing_inputs (never recomputed)", async () => {
    const { GET } = await import("./route");
    const database = db(
      { data: { raw_text: "", period_label: "" }, error: null },
      {
        data: {
          id: "rate-1",
          account_id: "account-a",
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
            missing_inputs: null,
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
            // Deliberately not derivable from the current rates above (which
            // would compute to ["usdtSellCup"] too) -- a distinct historical
            // value proves this is read straight off the column, not
            // recomputed live against today's rates.
            missing_inputs: ["usdtSellCup", "usdtBuyGyd"],
          },
        ],
        error: null,
      },
    );
    supabaseAdmin.mockReturnValue(database);

    const response = await GET();
    const body = await response.json();

    expect(body.chatOperations.entries).toHaveLength(2);
    expect(body.chatOperations.entries[0].missingRates).toEqual([]);
    expect(body.chatOperations.entries[1].missingRates).toEqual(["usdtSellCup", "usdtBuyGyd"]);
    expect(body.chatOperations.totals).toEqual({ facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, count: 1 });
  });

  it("excludes void entries from chatOperations by filtering the query", async () => {
    const { GET } = await import("./route");
    const database = db();
    supabaseAdmin.mockReturnValue(database);

    await GET();

    expect(database.chatEntriesBuilder.eq).toHaveBeenCalledWith("source", "completed_operation");
    expect(database.chatEntriesBuilder.neq).toHaveBeenCalledWith("status", "void");
  });
});

describe("POST /api/calculadora", () => {
  function okBuilder() {
    return queryBuilder({
      data: { raw_text: "text", period_label: "SEMANA 1" },
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

    const response = await POST(jsonRequest({}));

    expect(response.status).toBe(400);
  });

  it("persists only raw_text, period_label, updated_by, updated_at -- never the rate columns", async () => {
    const { POST } = await import("./route");
    const builder = okBuilder();
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await POST(jsonRequest({
      rawText: "text",
      periodo: "SEMANA 1",
      // Even if an old client still sends these, the route must never write
      // them -- rates are written only through POST /api/calculator/rates.
      tarifa: 3,
      compraUsdtGyd: 235,
      ventaUsdtGyd: 260,
      ventaUsdtCup: 975,
    }));

    expect(response.status).toBe(200);
    const [[payload]] = builder.upsert.mock.calls as unknown as [[Record<string, unknown>]];
    expect(payload).toEqual({
      account_id: "account-a",
      raw_text: "text",
      period_label: "SEMANA 1",
      updated_by: "user-a",
      updated_at: expect.any(String),
    });
    expect(await response.json()).toEqual({ rawText: "text", periodo: "SEMANA 1" });
  });

  it("save failure maps to 500", async () => {
    const { POST } = await import("./route");
    const builder = queryBuilder({ data: null, error: { message: "boom" } });
    supabaseAdmin.mockReturnValue({ from: vi.fn(() => builder) });

    const response = await POST(jsonRequest({ rawText: "", periodo: "" }));

    expect(response.status).toBe(500);
  });
});
