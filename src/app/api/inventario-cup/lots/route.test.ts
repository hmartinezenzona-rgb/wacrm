// POST /api/inventario-cup/lots -- load a CUP lot on a card (admin+) via crm_cargar_lote_cup.

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

const CARD_ID = "11111111-1111-1111-1111-111111111111";
const LOT_ROW = { id: "lot-1", account_id: "account-a", card_id: CARD_ID, amount_cup: "500000", remaining_cup: "500000", rate_cup_per_usdt: "960", loaded_at: "2026-10-14T12:00:00Z", note: "compra A" };

describe("POST /api/inventario-cup/lots", () => {
  it("requires admin", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await POST(post("/x", { cardId: CARD_ID, amountCup: 1, rateCupPerUsdt: 1 }))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it.each([
    ["no cardId", { amountCup: 1, rateCupPerUsdt: 1 }],
    ["amount zero", { cardId: CARD_ID, amountCup: 0, rateCupPerUsdt: 960 }],
    ["rate negative", { cardId: CARD_ID, amountCup: 100, rateCupPerUsdt: -1 }],
    ["remainingCup is not accepted", { cardId: CARD_ID, amountCup: 100, rateCupPerUsdt: 960, remainingCup: 1 }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await POST(post("/x", body))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("loads the lot: acceptance example 500000 CUP at 960", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: LOT_ROW, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await POST(post("/x", { cardId: CARD_ID, amountCup: 500000, rateCupPerUsdt: 960, note: "compra A" }));

    expect(response.status).toBe(201);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_cargar_lote_cup", {
      p_account_id: "account-a", p_card_id: CARD_ID, p_amount_cup: 500000, p_rate_cup_per_usdt: 960, p_note: "compra A", p_loaded_at: null,
    });
    expect((await response.json()).lot).toMatchObject({ id: "lot-1", amountCup: 500000, remainingCup: 500000, rateCupPerUsdt: 960, note: "compra A" });
  });

  it("maps P0002 (unknown card) to 404 and 22023 (inactive card) to 400", async () => {
    const { POST } = await import("./route");
    const body = { cardId: CARD_ID, amountCup: 100, rateCupPerUsdt: 960 };
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "P0002", message: "card not found" } }));
    expect((await POST(post("/x", body))).status).toBe(404);
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "22023", message: "the card is inactive" } }));
    expect((await POST(post("/x", body))).status).toBe(400);
  });
});
