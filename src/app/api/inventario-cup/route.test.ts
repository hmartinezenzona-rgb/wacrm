// GET /api/inventario-cup -- the CUP inventory report (admin+), via crm_inventario_cup (migration 239).

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

function ctx(rpcResult: { data: unknown; error: unknown }) {
  const rpc = vi.fn(() => Promise.resolve(rpcResult));
  return { supabase: { rpc }, userId: "user-a", accountId: "account-a", role: "admin" as const, account: { id: "account-a", name: "A" } };
}

const post = (url: string, body?: unknown, raw?: string, method = "POST") =>
  new Request(`http://local${url}`, { method, body: raw ?? (body === undefined ? undefined : JSON.stringify(body)) });

beforeEach(() => vi.clearAllMocks());

const REPORT = {
  cuba_day: "2026-10-14",
  cards: [
    {
      id: "card-1", name: "Tarjeta A", last4: "1234", priority: 1, active: true, daily_limit_cup: "120000",
      balance_cup: "500000", used_today_cup: "0", remaining_limit_today_cup: "120000",
      lots: [{ id: "lot-1", amount_cup: "500000", remaining_cup: "500000", rate_cup_per_usdt: "960", loaded_at: "2026-10-14T12:00:00Z", note: null, editable: true }],
    },
  ],
};

describe("GET /api/inventario-cup", () => {
  it("requires admin: below admin -> 403, unauthenticated -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await GET(post("/api/inventario-cup", undefined, undefined, "GET"))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });
    expect((await GET(post("/api/inventario-cup", undefined, undefined, "GET"))).status).toBe(401);
  });

  it("returns the mapped report of the caller's account, never cached", async () => {
    const { GET } = await import("./route");
    const c = ctx({ data: REPORT, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await GET(post("/api/inventario-cup", undefined, undefined, "GET"));

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_inventario_cup", { p_account_id: "account-a", p_include_inactive: false });
    const body = await response.json();
    expect(body.cubaDay).toBe("2026-10-14");
    expect(body.cards[0]).toMatchObject({ id: "card-1", dailyLimitCup: 120000, balanceCup: 500000, remainingLimitTodayCup: 120000 });
    expect(body.cards[0].lots[0]).toMatchObject({ rateCupPerUsdt: 960, editable: true });
  });

  it("?includeInactive=1 asks for the inactive cards too", async () => {
    const { GET } = await import("./route");
    const c = ctx({ data: REPORT, error: null });
    requireRole.mockResolvedValueOnce(c);

    await GET(post("/api/inventario-cup?includeInactive=1", undefined, undefined, "GET"));

    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_inventario_cup", { p_account_id: "account-a", p_include_inactive: true });
  });

  it("maps RPC 42501 to 403 and an unexpected error to 500", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "42501", message: "nope" } }));
    expect((await GET(post("/api/inventario-cup", undefined, undefined, "GET"))).status).toBe(403);

    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "XX000", message: "boom" } }));
    expect((await GET(post("/api/inventario-cup", undefined, undefined, "GET"))).status).toBe(500);
    spy.mockRestore();
  });
});
