// POST /api/inventario-cup/cards -- create a sending card (admin+) via crm_guardar_tarjeta_cup.

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

const CARD_ROW = { id: "card-1", account_id: "account-a", name: "Tarjeta A", last4: "1234", priority: 1, daily_limit_cup: "120000", active: true };

describe("POST /api/inventario-cup/cards", () => {
  it("requires admin", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    const response = await POST(post("/api/inventario-cup/cards", { name: "A" }));
    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("invalid JSON -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));
    expect((await POST(post("/api/inventario-cup/cards", undefined, "{nope"))).status).toBe(400);
  });

  it.each([
    ["no name", {}],
    ["bad last4", { name: "A", last4: "12" }],
    ["limit zero", { name: "A", dailyLimitCup: 0 }],
    ["unknown key (accountId)", { name: "A", accountId: "other" }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await POST(post("/api/inventario-cup/cards", body))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("creates the card with the caller's account and the RPC argument names", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: CARD_ROW, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await POST(post("/api/inventario-cup/cards", { name: " Tarjeta A ", last4: "1234", priority: 1, dailyLimitCup: 90000 }));

    expect(response.status).toBe(201);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_guardar_tarjeta_cup", {
      p_account_id: "account-a", p_card_id: null, p_name: "Tarjeta A", p_last4: "1234", p_priority: 1, p_daily_limit_cup: 90000, p_active: null,
    });
    expect((await response.json()).card).toMatchObject({ id: "card-1", name: "Tarjeta A", last4: "1234", dailyLimitCup: 120000, active: true });
  });

  it("maps RPC 22023 (duplicate name) to 400 with its message, and 42501 to 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "22023", message: "an active card with that name already exists" } }));
    const dup = await POST(post("/api/inventario-cup/cards", { name: "A" }));
    expect(dup.status).toBe(400);
    expect((await dup.json()).error).toMatch(/already exists/);

    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "42501", message: "x" } }));
    expect((await POST(post("/api/inventario-cup/cards", { name: "A" }))).status).toBe(403);
  });
});
