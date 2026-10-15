// PATCH / DELETE /api/inventario-cup/lots/{lotId} -- correct or delete an unconsumed lot (admin+).

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

const LOT_ID = "22222222-2222-2222-2222-222222222222";
const params = (lotId: string) => ({ params: Promise.resolve({ lotId }) });
const LOT_ROW = { id: LOT_ID, account_id: "account-a", card_id: "card-1", amount_cup: "400000", remaining_cup: "400000", rate_cup_per_usdt: "975", loaded_at: "2026-10-14T12:00:00Z", note: null };

describe("PATCH /api/inventario-cup/lots/[lotId]", () => {
  it("requires admin", async () => {
    const { PATCH } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await PATCH(post("/x", { amountCup: 1 }, undefined, "PATCH"), params(LOT_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("malformed id / empty body / cardId -> 400, RPC never called", async () => {
    const { PATCH } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValue(c);
    expect((await PATCH(post("/x", { amountCup: 1 }, undefined, "PATCH"), params("nope"))).status).toBe(400);
    expect((await PATCH(post("/x", {}, undefined, "PATCH"), params(LOT_ID))).status).toBe(400);
    expect((await PATCH(post("/x", { cardId: LOT_ID, amountCup: 1 }, undefined, "PATCH"), params(LOT_ID))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("corrects amount and rate; NULL keeps the rest; note null clears it", async () => {
    const { PATCH } = await import("./route");
    const c = ctx({ data: LOT_ROW, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await PATCH(post("/x", { amountCup: 400000, rateCupPerUsdt: 975, note: null }, undefined, "PATCH"), params(LOT_ID));

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_corregir_lote_cup", {
      p_lot_id: LOT_ID, p_amount_cup: 400000, p_rate_cup_per_usdt: 975, p_note: "",
    });
    expect((await response.json()).lot).toMatchObject({ id: LOT_ID, amountCup: 400000, rateCupPerUsdt: 975 });
  });

  it("a consumed lot (22023) -> 400 with the message; unknown lot -> 404", async () => {
    const { PATCH } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "22023", message: "the lot was already consumed and cannot be corrected" } }));
    const consumed = await PATCH(post("/x", { amountCup: 1 }, undefined, "PATCH"), params(LOT_ID));
    expect(consumed.status).toBe(400);
    expect((await consumed.json()).error).toMatch(/already consumed/);
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "P0002", message: "lot not found" } }));
    expect((await PATCH(post("/x", { amountCup: 1 }, undefined, "PATCH"), params(LOT_ID))).status).toBe(404);
  });
});

describe("DELETE /api/inventario-cup/lots/[lotId]", () => {
  it("requires admin", async () => {
    const { DELETE } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await DELETE(post("/x", undefined, undefined, "DELETE"), params(LOT_ID))).status).toBe(403);
  });

  it("malformed id -> 400", async () => {
    const { DELETE } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await DELETE(post("/x", undefined, undefined, "DELETE"), params("nope"))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("deletes through crm_eliminar_lote_cup", async () => {
    const { DELETE } = await import("./route");
    const c = ctx({ data: LOT_ID, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await DELETE(post("/x", undefined, undefined, "DELETE"), params(LOT_ID));

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_eliminar_lote_cup", { p_lot_id: LOT_ID });
    expect(await response.json()).toEqual({ deleted: LOT_ID });
  });

  it("a consumed lot (22023) -> 400; unknown -> 404", async () => {
    const { DELETE } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "22023", message: "the lot was already consumed and cannot be deleted" } }));
    expect((await DELETE(post("/x", undefined, undefined, "DELETE"), params(LOT_ID))).status).toBe(400);
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "P0002", message: "lot not found" } }));
    expect((await DELETE(post("/x", undefined, undefined, "DELETE"), params(LOT_ID))).status).toBe(404);
  });
});
