// POST /api/inventario-usd/cards/[cardId]/balance -- set the real balance of a card (admin+) via crm_ajustar_saldo_usd.

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
const params = (cardId: string) => ({ params: Promise.resolve({ cardId }) });
const RESULT = { card_id: CARD_ID, saldo_anterior: "400", saldo_nuevo: "395", movimientos: [{ lot_id: "lot-1", amount_usd: "5" }] };

describe("POST /api/inventario-usd/cards/[cardId]/balance", () => {
  it("requires admin", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await POST(post("/x", { balanceUsd: 1 }), params(CARD_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("malformed id / bad body -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValue(c);
    expect((await POST(post("/x", { balanceUsd: 1 }), params("nope"))).status).toBe(400);
    expect((await POST(post("/x", { balanceUsd: -1 }), params(CARD_ID))).status).toBe(400);
    expect((await POST(post("/x", {}), params(CARD_ID))).status).toBe(400);
    expect((await POST(post("/x", undefined, "{nope"), params(CARD_ID))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("adjusts through crm_ajustar_saldo_usd and maps the result", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: RESULT, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await POST(post("/x", { balanceUsd: 395, reason: "bank fee" }), params(CARD_ID));

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_ajustar_saldo_usd", { p_card_id: CARD_ID, p_saldo_usd: 395, p_motivo: "bank fee" });
    expect((await response.json()).balance).toEqual({ cardId: CARD_ID, previousBalanceUsd: 400, newBalanceUsd: 395, movements: [{ lotId: "lot-1", amountUsd: 5 }] });
  });

  it("above what was loaded (22023) -> 400 with the message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "22023", message: "the balance cannot exceed what was loaded on the card (500 USD): load a new lot" } }));
    const response = await POST(post("/x", { balanceUsd: 900 }), params(CARD_ID));
    expect(response.status).toBe(400);
    expect((await response.json()).error).toMatch(/load a new lot/);
  });
});
