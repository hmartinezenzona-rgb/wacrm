// GET/POST /api/calculadora/weeks: the archived weeks list and the weekly cut ("Limpiar todo"). The cut itself is
// guarded by supabase/staging/assertions/calculator-weekly-cut.sql.

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

const WEEK_ROW = {
  id: "week-1",
  cut_at: "2026-10-03T12:00:00+00:00",
  raw_text: "5 zelle 100",
  period_label: "SEMANA 1",
  manual_totals: { facturado_gyd: 100, invertido_gyd: 80, retorno_gyd: 20 },
  chat_totals: { count: 1, facturado_gyd: 26000, invertido_gyd: 24000, retorno_gyd: 2000 },
  entries: [],
};

function account(overrides: { listResult?: { data: unknown; error: unknown }; rpcResult?: { data: unknown; error: unknown } } = {}) {
  const listBuilder = {
    select: vi.fn(() => listBuilder),
    eq: vi.fn(() => listBuilder),
    order: vi.fn(() => listBuilder),
    limit: vi.fn(() => Promise.resolve(overrides.listResult ?? { data: [WEEK_ROW], error: null })),
  };
  const supabase = {
    from: vi.fn(() => listBuilder),
    rpc: vi.fn(() => Promise.resolve(overrides.rpcResult ?? { data: WEEK_ROW, error: null })),
  };
  getCurrentAccount.mockResolvedValue({ accountId: "account-a", userId: "user-a", role: "agent", supabase });
  return { supabase, listBuilder };
}

function post(body: unknown, raw?: string) {
  return new Request("http://local/api/calculadora/weeks", { method: "POST", body: raw ?? JSON.stringify(body) });
}

const VALID = { rawText: "5 zelle 100", periodo: "SEMANA 1" };

beforeEach(() => {
  vi.clearAllMocks();
  canSendMessages.mockImplementation(() => true);
});

describe("GET /api/calculadora/weeks", () => {
  it("lists the account's archived weeks newest first, as summaries without the text or the entries", async () => {
    const { GET } = await import("./route");
    const { supabase, listBuilder } = account();
    const response = await GET();
    expect(response.status).toBe(200);
    expect(supabase.from).toHaveBeenCalledWith("remittance_calculator_weeks");
    expect(listBuilder.eq).toHaveBeenCalledWith("account_id", "account-a");
    expect(listBuilder.order).toHaveBeenCalledWith("cut_at", { ascending: false });
    const body = await response.json();
    expect(body.weeks).toEqual([
      {
        id: "week-1", cutAt: "2026-10-03T12:00:00+00:00", periodo: "SEMANA 1",
        manualTotals: { facturadoGyd: 100, invertidoGyd: 80, retornoGyd: 20 },
        chatTotals: { count: 1, facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000 },
      },
    ]);
    expect(body.weeks[0].rawText).toBeUndefined();
  });

  it("a viewer is refused", async () => {
    const { GET } = await import("./route");
    account();
    canSendMessages.mockImplementation(() => false);
    expect((await GET()).status).toBe(403);
  });

  it("a read failure -> 500", async () => {
    const { GET } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    account({ listResult: { data: null, error: { message: "boom" } } });
    expect((await GET()).status).toBe(500);
  });
});

describe("POST /api/calculadora/weeks (the weekly cut)", () => {
  it("sends only the text and the period to crm_cerrar_semana_calculadora (the totals are computed in SQL) and answers with the cut", async () => {
    const { POST } = await import("./route");
    const { supabase } = account();
    const response = await POST(post(VALID));
    expect(response.status).toBe(200);
    expect(supabase.rpc).toHaveBeenCalledWith("crm_cerrar_semana_calculadora", {
      p_account_id: "account-a",
      p_raw_text: "5 zelle 100",
      p_period_label: "SEMANA 1",
    });
    const body = await response.json();
    expect(body.cutAt).toBe("2026-10-03T12:00:00+00:00");
    expect(body.week).toMatchObject({ id: "week-1", rawText: "5 zelle 100", periodo: "SEMANA 1" });
  });

  it("a viewer is refused and the RPC never runs", async () => {
    const { POST } = await import("./route");
    const { supabase } = account();
    canSendMessages.mockImplementation(() => false);
    expect((await POST(post(VALID))).status).toBe(403);
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it.each([
    ["invalid JSON", undefined, "{nope"],
    ["rawText missing", { ...VALID, rawText: undefined }, undefined],
    ["periodo missing", { ...VALID, periodo: undefined }, undefined],
  ])("%s -> 400, RPC never called", async (_label, body, raw) => {
    const { POST } = await import("./route");
    const { supabase } = account();
    expect((await POST(post(body, raw))).status).toBe(400);
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it.each([
    ["42501", 403],
    ["22023", 400],
  ])("RPC error %s -> %i", async (code, status) => {
    const { POST } = await import("./route");
    account({ rpcResult: { data: null, error: { code, message: "boom" } } });
    expect((await POST(post(VALID))).status).toBe(status);
  });

  it("an unexpected RPC error -> 500", async () => {
    const { POST } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    account({ rpcResult: { data: null, error: { code: "XX000", message: "db down" } } });
    expect((await POST(post(VALID))).status).toBe(500);
  });

  it("ignores the totals and lines an older page still sends: the cut is the only RPC and it takes only the text and the period", async () => {
    const { POST } = await import("./route");
    const { supabase } = account();
    const response = await POST(post({ ...VALID, manualTotals: { facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 1 }, manualLines: [{ service: "NOPE" }] }));
    expect(response.status).toBe(200);
    expect(supabase.rpc.mock.calls).toEqual([
      ["crm_cerrar_semana_calculadora", { p_account_id: "account-a", p_raw_text: "5 zelle 100", p_period_label: "SEMANA 1" }],
    ]);
  });
});
