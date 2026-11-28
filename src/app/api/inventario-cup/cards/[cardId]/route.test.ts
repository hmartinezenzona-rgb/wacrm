// PATCH /api/inventario-cup/cards/{cardId} -- update / reorder / deactivate a card (admin+).

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
const CARD_ROW = { id: CARD_ID, account_id: "account-a", name: "Tarjeta A", last4: null, priority: 2, daily_limit_cup: "120000", active: false };

describe("PATCH /api/inventario-cup/cards/[cardId]", () => {
  it("requires admin", async () => {
    const { PATCH } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await PATCH(post("/x", { active: false }, undefined, "PATCH"), params(CARD_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("malformed id -> 400; empty or unknown-key body -> 400; RPC never called", async () => {
    const { PATCH } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValue(c);
    expect((await PATCH(post("/x", { active: false }, undefined, "PATCH"), params("nope"))).status).toBe(400);
    expect((await PATCH(post("/x", {}, undefined, "PATCH"), params(CARD_ID))).status).toBe(400);
    expect((await PATCH(post("/x", { accountId: "z" }, undefined, "PATCH"), params(CARD_ID))).status).toBe(400);
    expect((await PATCH(post("/x", undefined, "{bad", "PATCH"), params(CARD_ID))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("passes only the named fields (NULL keeps) and null last4 clears it", async () => {
    const { PATCH } = await import("./route");
    const c = ctx({ data: CARD_ROW, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await PATCH(post("/x", { priority: 2, last4: null, active: false }, undefined, "PATCH"), params(CARD_ID));

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_guardar_tarjeta_cup", {
      p_account_id: "account-a", p_card_id: CARD_ID, p_name: null, p_last4: "", p_priority: 2, p_daily_limit_cup: null, p_active: false,
    });
    expect((await response.json()).card).toMatchObject({ id: CARD_ID, priority: 2, active: false, last4: null });
  });

  it("maps P0002 to 404", async () => {
    const { PATCH } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "P0002", message: "card not found" } }));
    expect((await PATCH(post("/x", { active: true }, undefined, "PATCH"), params(CARD_ID))).status).toBe(404);
  });
});
