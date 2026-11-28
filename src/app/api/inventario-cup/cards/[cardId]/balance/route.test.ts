// POST /api/inventario-cup/cards/{cardId}/balance -- set the real balance of a sending card (admin+).

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

const post = (body?: unknown, raw?: string) =>
  new Request("http://local/x", { method: "POST", body: raw ?? (body === undefined ? undefined : JSON.stringify(body)) });

beforeEach(() => vi.clearAllMocks());

const CARD_ID = "11111111-1111-1111-1111-111111111111";
const LOT_ID = "22222222-2222-2222-2222-222222222222";
const params = (cardId: string) => ({ params: Promise.resolve({ cardId }) });
const RESULT = {
  card_id: CARD_ID,
  saldo_anterior: "240000",
  saldo_nuevo: "222840",
  movimientos: [{ lot_id: LOT_ID, amount_cup: "17160" }],
};

describe("POST /api/inventario-cup/cards/[cardId]/balance", () => {
  it("requires admin", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await POST(post({ balanceCup: 1 }), params(CARD_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("malformed id / bad body -> 400 and the RPC is never called", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValue(c);
    expect((await POST(post({ balanceCup: 1 }), params("nope"))).status).toBe(400);
    expect((await POST(post(undefined, "{not json"), params(CARD_ID))).status).toBe(400);
    expect((await POST(post({}), params(CARD_ID))).status).toBe(400);
    expect((await POST(post({ balanceCup: -1 }), params(CARD_ID))).status).toBe(400);
    expect((await POST(post({ balanceCup: "5" }), params(CARD_ID))).status).toBe(400);
    expect((await POST(post({ balanceCup: 5, extra: 1 }), params(CARD_ID))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("adjusts through crm_ajustar_saldo_cup and maps the result", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: RESULT, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await POST(post({ balanceCup: 222840, reason: " conteo real " }), params(CARD_ID));

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_ajustar_saldo_cup", {
      p_card_id: CARD_ID,
      p_saldo_cup: 222840,
      p_motivo: "conteo real",
    });
    expect((await response.json()).balance).toEqual({
      cardId: CARD_ID,
      previousBalanceCup: 240000,
      newBalanceCup: 222840,
      movements: [{ lotId: LOT_ID, amountCup: 17160 }],
    });
  });

  it("zero is a valid balance and a missing reason is sent as null", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: { ...RESULT, saldo_nuevo: 0, movimientos: [] }, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await POST(post({ balanceCup: 0 }), params(CARD_ID))).status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_ajustar_saldo_cup", { p_card_id: CARD_ID, p_saldo_cup: 0, p_motivo: null });
  });

  it("above what was loaded (22023) -> 400 with the message; non-admin DB refusal -> 403; unknown card -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "22023", message: "the balance cannot exceed what was loaded on the card (300000 CUP): load a new lot" } }));
    const over = await POST(post({ balanceCup: 400000 }), params(CARD_ID));
    expect(over.status).toBe(400);
    expect((await over.json()).error).toMatch(/load a new lot/);
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "42501", message: "not authorized" } }));
    expect((await POST(post({ balanceCup: 1 }), params(CARD_ID))).status).toBe(403);
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "P0002", message: "card not found" } }));
    expect((await POST(post({ balanceCup: 1 }), params(CARD_ID))).status).toBe(404);
  });

  it("any other database error -> 500 without leaking the message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "XX000", message: "boom" } }));
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await POST(post({ balanceCup: 1 }), params(CARD_ID));
    spy.mockRestore();
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain("boom");
  });
});
