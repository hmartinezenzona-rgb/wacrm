// PATCH / DELETE /api/inventario-usd/lots/[lotId] -- correct or delete an unconsumed USD lot (admin+).

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
const LOT_ROW = { id: LOT_ID, card_id: "card-1", amount_usd: "400", remaining_usd: "400", usdt_paid: "380", usd_per_usdt: "1.0526", loaded_at: "2026-11-02T12:00:00Z", note: null };
const patch = (body?: unknown) => post("/x", body, undefined, "PATCH");
const del = () => post("/x", undefined, undefined, "DELETE");

describe("PATCH /api/inventario-usd/lots/[lotId]", () => {
  it("requires admin", async () => {
    const { PATCH } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await PATCH(patch({ amountUsd: 1 }), params(LOT_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("malformed id / empty body / cardId -> 400, RPC never called", async () => {
    const { PATCH } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValue(c);
    expect((await PATCH(patch({ amountUsd: 1 }), params("nope"))).status).toBe(400);
    expect((await PATCH(patch({}), params(LOT_ID))).status).toBe(400);
    expect((await PATCH(patch({ cardId: LOT_ID, amountUsd: 1 }), params(LOT_ID))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("corrects amount and USDT paid; NULL keeps the rest; note null clears it", async () => {
    const { PATCH } = await import("./route");
    const c = ctx({ data: LOT_ROW, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await PATCH(patch({ amountUsd: 400, usdtPaid: 380, note: null }), params(LOT_ID));

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_corregir_lote_usd", { p_lot_id: LOT_ID, p_amount_usd: 400, p_usdt_paid: 380, p_note: "" });
    expect((await response.json()).lot).toMatchObject({ id: LOT_ID, amountUsd: 400, usdtPaid: 380 });
  });

  it("a consumed lot (22023) -> 400; unknown lot -> 404", async () => {
    const { PATCH } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "22023", message: "the lot was already consumed and cannot be corrected" } }));
    const consumed = await PATCH(patch({ amountUsd: 1 }), params(LOT_ID));
    expect(consumed.status).toBe(400);
    expect((await consumed.json()).error).toMatch(/already consumed/);
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "P0002", message: "lot not found" } }));
    expect((await PATCH(patch({ amountUsd: 1 }), params(LOT_ID))).status).toBe(404);
  });
});

describe("DELETE /api/inventario-usd/lots/[lotId]", () => {
  it("requires admin", async () => {
    const { DELETE } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await DELETE(del(), params(LOT_ID))).status).toBe(403);
  });

  it("malformed id -> 400", async () => {
    const { DELETE } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await DELETE(del(), params("nope"))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("deletes through crm_eliminar_lote_usd", async () => {
    const { DELETE } = await import("./route");
    const c = ctx({ data: LOT_ID, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await DELETE(del(), params(LOT_ID));

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_eliminar_lote_usd", { p_lot_id: LOT_ID });
    expect(await response.json()).toEqual({ deleted: LOT_ID });
  });

  it("a consumed lot (22023) -> 400; unknown -> 404", async () => {
    const { DELETE } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "22023", message: "the lot was already consumed and cannot be deleted" } }));
    expect((await DELETE(del(), params(LOT_ID))).status).toBe(400);
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "P0002", message: "lot not found" } }));
    expect((await DELETE(del(), params(LOT_ID))).status).toBe(404);
  });
});
