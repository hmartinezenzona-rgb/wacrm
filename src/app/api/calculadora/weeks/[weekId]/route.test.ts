// GET /api/calculadora/weeks/{weekId}: one archived week, read-only (text, period, totals, entries).

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

const WEEK_ID = "22222222-2222-2222-2222-222222222222";
const WEEK_ROW = {
  id: WEEK_ID,
  cut_at: "2026-10-03T12:00:00+00:00",
  raw_text: "5 zelle 100",
  period_label: "SEMANA 1",
  manual_totals: { facturado_gyd: 100, invertido_gyd: 80, retorno_gyd: 20 },
  chat_totals: { count: 1, facturado_gyd: 26000, invertido_gyd: 24000, retorno_gyd: 2000 },
  entries: [{ id: "e1", operation_id: "op1", service: "ZELLE", customer_name: "Raúl", amount: 100, amount_currency: "USD", entry_date: "2026-10-01", facturado_gyd: 26000, invertido_gyd: 24000, retorno_gyd: 2000 }],
};

function account(result: { data: unknown; error: unknown }) {
  const builder = {
    select: vi.fn(() => builder),
    eq: vi.fn(() => builder),
    maybeSingle: vi.fn(() => Promise.resolve(result)),
  };
  const supabase = { from: vi.fn(() => builder) };
  getCurrentAccount.mockResolvedValue({ accountId: "account-a", userId: "user-a", role: "agent", supabase });
  return { supabase, builder };
}

const request = () => new Request(`http://local/api/calculadora/weeks/${WEEK_ID}`);
const paramsFor = (weekId: string) => ({ params: Promise.resolve({ weekId }) });

beforeEach(() => {
  vi.clearAllMocks();
  canSendMessages.mockImplementation(() => true);
});

describe("GET /api/calculadora/weeks/[weekId]", () => {
  it("returns the whole archived week of the caller's account", async () => {
    const { GET } = await import("./route");
    const { supabase, builder } = account({ data: WEEK_ROW, error: null });
    const response = await GET(request(), paramsFor(WEEK_ID));
    expect(response.status).toBe(200);
    expect(supabase.from).toHaveBeenCalledWith("remittance_calculator_weeks");
    expect(builder.eq).toHaveBeenCalledWith("id", WEEK_ID);
    expect(builder.eq).toHaveBeenCalledWith("account_id", "account-a");
    const body = await response.json();
    expect(body.week.rawText).toBe("5 zelle 100");
    expect(body.week.entries).toHaveLength(1);
    expect(body.week.entries[0]).toMatchObject({ id: "e1", customerName: "Raúl", status: "completed" });
  });

  it("a malformed id -> 400", async () => {
    const { GET } = await import("./route");
    account({ data: null, error: null });
    expect((await GET(request(), paramsFor("nope"))).status).toBe(400);
  });

  it("no such week for this account -> 404", async () => {
    const { GET } = await import("./route");
    account({ data: null, error: null });
    expect((await GET(request(), paramsFor(WEEK_ID))).status).toBe(404);
  });

  it("a viewer is refused", async () => {
    const { GET } = await import("./route");
    account({ data: WEEK_ROW, error: null });
    canSendMessages.mockImplementation(() => false);
    expect((await GET(request(), paramsFor(WEEK_ID))).status).toBe(403);
  });

  it("a read failure -> 500", async () => {
    const { GET } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    account({ data: null, error: { message: "boom" } });
    expect((await GET(request(), paramsFor(WEEK_ID))).status).toBe(500);
  });
});
