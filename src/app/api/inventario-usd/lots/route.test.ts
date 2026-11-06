// POST /api/inventario-usd/lots -- load a lot of USD (amount and USDT paid) on a card (admin+) via crm_cargar_lote_usd.

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
const LOT_ROW = { id: "lot-1", account_id: "account-a", card_id: CARD_ID, amount_usd: "500", remaining_usd: "500", usdt_paid: "476.19", usd_per_usdt: "1.05", loaded_at: "2026-11-02T12:00:00Z", note: null };

describe("POST /api/inventario-usd/lots", () => {
  it("requires admin", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await POST(post("/x", { cardId: CARD_ID, amountUsd: 500, usdtPaid: 476.19 }))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it.each([
    ["no card", { amountUsd: 500, usdtPaid: 476.19 }],
    ["no usdtPaid", { cardId: CARD_ID, amountUsd: 500 }],
    ["zero amount", { cardId: CARD_ID, amountUsd: 0, usdtPaid: 1 }],
    ["unknown key", { cardId: CARD_ID, amountUsd: 5, usdtPaid: 5, accountId: "x" }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await POST(post("/x", body))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));
    expect((await POST(post("/x", undefined, "{nope"))).status).toBe(400);
  });

  it("loads the lot with the caller's account and the RPC argument names", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: LOT_ROW, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await POST(post("/x", { cardId: CARD_ID, amountUsd: 500, usdtPaid: 476.19, note: "primera" }));

    expect(response.status).toBe(201);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_cargar_lote_usd", {
      p_account_id: "account-a", p_card_id: CARD_ID, p_amount_usd: 500, p_usdt_paid: 476.19, p_loaded_at: null, p_note: "primera",
    });
    expect((await response.json()).lot).toMatchObject({ id: "lot-1", cardId: CARD_ID, amountUsd: 500, usdtPaid: 476.19, usdPerUsdt: 1.05 });
  });

  it("inactive card (22023) -> 400, unknown card -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "22023", message: "the card is inactive" } }));
    expect((await POST(post("/x", { cardId: CARD_ID, amountUsd: 5, usdtPaid: 5 }))).status).toBe(400);
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "P0002", message: "card not found" } }));
    expect((await POST(post("/x", { cardId: CARD_ID, amountUsd: 5, usdtPaid: 5 }))).status).toBe(404);
  });
});
