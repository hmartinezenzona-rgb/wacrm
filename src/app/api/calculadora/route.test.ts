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
  cutResult: { data: unknown; error: unknown } = { data: null, error: null },
) {
  const documentBuilder = queryBuilder(documentResult);
  const rateBuilder = queryBuilder(rateResult);
  const chatEntriesBuilder = queryBuilder(chatEntriesResult);
  const cutBuilder = queryBuilder(cutResult);
  return {
    from: vi.fn((table: string) => {
      if (table === "calculator_current_entries") return chatEntriesBuilder;
      if (table === "remittance_calculator_weeks") return cutBuilder;
      if (table === "calculator_rate_versions") return rateBuilder;
      return documentBuilder;
    }),
    rpc: vi.fn(() =>
      Promise.resolve({
        data: { raw_text: "texto", period_label: "sem 1" },
        error: null,
      }),
    ),
    documentBuilder,
    rateBuilder,
    chatEntriesBuilder,
    cutBuilder,
  };
}

const supabaseAdmin = vi.fn();
vi.mock("@/lib/flows/admin-client", () => ({ supabaseAdmin: () => supabaseAdmin() }));

const ACCOUNT = { accountId: "account-a", userId: "user-a", role: "agent" };

/** Migration 106: this route runs on the CALLER'S session client, so the
 *  client under test is handed over through the account context rather
 *  than through the admin-client factory. */
function useClient<T>(client: T): T {
  getCurrentAccount.mockResolvedValue({ ...ACCOUNT, supabase: client });
  return client;
}

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

describe("session client only (migration 106)", () => {
  it("GET reads through the caller's session client, never the admin client", async () => {
    const { GET } = await import("./route");
    const client = db();
    getCurrentAccount.mockResolvedValue({ ...ACCOUNT, supabase: client });

    await GET();

    expect(client.from).toHaveBeenCalled();
    expect(supabaseAdmin).not.toHaveBeenCalled();
  });

  it("POST saves the document through crm_guardar_documento_calculadora, not a direct upsert", async () => {
    const { POST } = await import("./route");
    const client = db();
    getCurrentAccount.mockResolvedValue({ ...ACCOUNT, supabase: client });

    const response = await POST(jsonRequest({ rawText: "texto", periodo: "sem 1" }));

    expect(response.status).toBe(200);
    expect(client.rpc).toHaveBeenCalledWith("crm_guardar_documento_calculadora", {
      p_account_id: ACCOUNT.accountId,
      p_raw_text: "texto",
      p_period_label: "sem 1",
    });
    expect(client.documentBuilder.upsert).not.toHaveBeenCalled();
    expect(supabaseAdmin).not.toHaveBeenCalled();
  });
});

describe("POST /api/calculadora with the parsed manual lines (migration 228)", () => {
  const LINE = {
    position: 2, date: "2026-10-06", dayLabel: "Martes 6", customer: "Gerardo", service: "ZELLE", amount: 100,
    currency: "USD", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, rawLine: "• Gerardo 100 Zelle (240/260)",
  };
  const RPC_LINE = {
    position: 2, date: "2026-10-06", day_label: "Martes 6", customer: "Gerardo", service: "ZELLE", amount: 100,
    currency: "USD", facturado_gyd: 26000, invertido_gyd: 24000, retorno_gyd: 2000, raw_line: "• Gerardo 100 Zelle (240/260)",
  };

  function clientWith(sync: { data?: unknown; error?: { code?: string; message?: string } | null }) {
    const client = db();
    client.rpc.mockImplementation(((name: string) =>
      Promise.resolve(
        name === "crm_sincronizar_entradas_manuales"
          ? { data: sync.data ?? { count: 1 }, error: sync.error ?? null }
          : { data: { raw_text: "texto", period_label: "sem 1" }, error: null },
      )) as never);
    getCurrentAccount.mockResolvedValue({ ...ACCOUNT, supabase: client });
    return client;
  }

  it("saves the document, then syncs the manual entries with the same request", async () => {
    const { POST } = await import("./route");
    const client = clientWith({});

    const response = await POST(jsonRequest({ rawText: "texto", periodo: "sem 1", manualLines: [LINE] }));

    expect(response.status).toBe(200);
    expect(client.rpc.mock.calls.map((c: unknown[]) => c[0])).toEqual([
      "crm_guardar_documento_calculadora",
      "crm_sincronizar_entradas_manuales",
    ]);
    expect(client.rpc).toHaveBeenLastCalledWith("crm_sincronizar_entradas_manuales", {
      p_account_id: ACCOUNT.accountId,
      p_lineas: [RPC_LINE],
    });
    expect(await response.json()).toMatchObject({ rawText: "texto", periodo: "sem 1" });
  });

  it("an empty list syncs too (the week has no manual lines: the entries are cleared)", async () => {
    const { POST } = await import("./route");
    const client = clientWith({});

    await POST(jsonRequest({ rawText: "", periodo: "", manualLines: [] }));

    expect(client.rpc).toHaveBeenLastCalledWith("crm_sincronizar_entradas_manuales", { p_account_id: ACCOUNT.accountId, p_lineas: [] });
  });

  it("a request without manualLines (an older page) saves the text and never touches the entries", async () => {
    const { POST } = await import("./route");
    const client = clientWith({});

    const response = await POST(jsonRequest({ rawText: "texto", periodo: "sem 1" }));

    expect(response.status).toBe(200);
    expect(client.rpc.mock.calls.map((c: unknown[]) => c[0])).toEqual(["crm_guardar_documento_calculadora"]);
  });

  it("malformed manualLines -> 400 and nothing is saved", async () => {
    const { POST } = await import("./route");
    const client = clientWith({});

    const response = await POST(jsonRequest({ rawText: "texto", periodo: "sem 1", manualLines: [{ ...LINE, amount: "100" }] }));

    expect(response.status).toBe(400);
    expect(client.rpc).not.toHaveBeenCalled();
  });

  it("a refused sync is reported (the text is saved, the entries are not): the page must show an error", async () => {
    const { POST } = await import("./route");
    clientWith({ error: { code: "22023", message: "line 2: unknown service" } });

    const response = await POST(jsonRequest({ rawText: "texto", periodo: "sem 1", manualLines: [LINE] }));

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "line 2: unknown service", documentSaved: true, entriesSynced: false });
  });

  it("an unexpected sync failure -> 500 with documentSaved, never a silent success", async () => {
    const { POST } = await import("./route");
    clientWith({ error: { code: "XX000", message: "boom" } });
    vi.spyOn(console, "error").mockImplementation(() => {});

    const response = await POST(jsonRequest({ rawText: "texto", periodo: "sem 1", manualLines: [LINE] }));

    expect(response.status).toBe(500);
    expect(await response.json()).toMatchObject({ documentSaved: true, entriesSynced: false });
  });

  it("a document save failure does not try the sync", async () => {
    const { POST } = await import("./route");
    const client = db();
    client.rpc.mockImplementation((() => Promise.resolve({ data: null, error: { code: "42501", message: "no" } })) as never);
    getCurrentAccount.mockResolvedValue({ ...ACCOUNT, supabase: client });

    const response = await POST(jsonRequest({ rawText: "texto", periodo: "sem 1", manualLines: [LINE] }));

    expect(response.status).toBe(403);
    expect(client.rpc).toHaveBeenCalledTimes(1);
  });
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
    useClient(db());

    const response = await GET();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      rawText: "",
      periodo: "",
      tarifa: null,
      compraUsdtGyd: null,
      ventaUsdtGyd: null,
      ventaUsdtCup: null,
      cutAt: null,
      chatOperations: { entries: [], totals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 } },
    });
  });

  it("existing document text but no rate version yet -> text hydrates, rates stay null", async () => {
    const { GET } = await import("./route");
    const database = db({
      data: { raw_text: "• Fran 50k CUP (235/980)", period_label: "SEMANA 1" },
      error: null,
    });
    useClient(database);

    const response = await GET();

    expect(await response.json()).toEqual({
      rawText: "• Fran 50k CUP (235/980)",
      periodo: "SEMANA 1",
      tarifa: null,
      compraUsdtGyd: null,
      ventaUsdtGyd: null,
      ventaUsdtCup: null,
      cutAt: null,
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
    useClient(database);

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
    useClient(database);

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
    useClient(db({ data: null, error: { message: "boom" } }));

    const response = await GET();

    expect(response.status).toBe(500);
  });

  it("rate version read failure maps to 500", async () => {
    const { GET } = await import("./route");
    useClient(
      db({ data: null, error: null }, { data: null, error: { message: "boom" } }),
    );

    const response = await GET();

    expect(response.status).toBe(500);
  });

  it("chat entries read failure maps to 500", async () => {
    const { GET } = await import("./route");
    useClient(
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
    useClient(database);

    const response = await GET();
    const body = await response.json();

    expect(body.chatOperations.entries).toHaveLength(2);
    expect(body.chatOperations.entries[0].missingRates).toEqual([]);
    expect(body.chatOperations.entries[1].missingRates).toEqual(["usdtSellCup", "usdtBuyGyd"]);
    expect(body.chatOperations.totals).toEqual({ facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, count: 1 });
  });

  it("reads the chat entries from the Calculator view (not void, not archived by a weekly cut), never the raw table", async () => {
    const { GET } = await import("./route");
    const database = db();
    useClient(database);

    await GET();

    expect(database.from).toHaveBeenCalledWith("calculator_current_entries");
    expect(database.from).not.toHaveBeenCalledWith("remittance_calculator_entries");
    expect(database.chatEntriesBuilder.eq).toHaveBeenCalledWith("account_id", "account-a");
    expect(database.chatEntriesBuilder.neq).toHaveBeenCalledWith("status", "void");
  });

  it("answers the latest weekly cut so the page can filter live events", async () => {
    const { GET } = await import("./route");
    const database = db(undefined, undefined, undefined, { data: { cut_at: "2026-10-03T12:00:00+00:00" }, error: null });
    useClient(database);

    const body = await (await GET()).json();

    expect(database.from).toHaveBeenCalledWith("remittance_calculator_weeks");
    expect(database.cutBuilder.order).toHaveBeenCalledWith("cut_at", { ascending: false });
    expect(database.cutBuilder.limit).toHaveBeenCalledWith(1);
    expect(body.cutAt).toBe("2026-10-03T12:00:00+00:00");
  });

  it("no cut yet -> cutAt null", async () => {
    const { GET } = await import("./route");
    useClient(db());

    expect((await (await GET()).json()).cutAt).toBeNull();
  });

  it("a cut read failure maps to 500", async () => {
    const { GET } = await import("./route");
    useClient(db(undefined, undefined, undefined, { data: null, error: { message: "boom" } }));

    expect((await GET()).status).toBe(500);
  });
});

describe("POST /api/calculadora", () => {
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

  it("sends only the text and the period to the RPC -- never a rate, whatever the client posts", async () => {
    const { POST } = await import("./route");
    const client = db();
    useClient(client);

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
    // The RPC takes three arguments and none of them is a rate, so a stale
    // client posting rates cannot reach the rate columns through this route.
    expect(client.rpc).toHaveBeenCalledWith("crm_guardar_documento_calculadora", {
      p_account_id: "account-a",
      p_raw_text: "text",
      p_period_label: "SEMANA 1",
    });
  });

  it("save failure maps to 500", async () => {
    const { POST } = await import("./route");
    useClient({
      from: vi.fn(() => queryBuilder({ data: null, error: null })),
      rpc: vi.fn(() => Promise.resolve({ data: null, error: { message: "boom" } })),
    });

    const response = await POST(jsonRequest({ rawText: "", periodo: "" }));

    expect(response.status).toBe(500);
  });
});
