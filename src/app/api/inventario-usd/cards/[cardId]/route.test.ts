// PATCH /api/inventario-usd/cards/[cardId] -- update, reorder or deactivate a card (admin+).

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
const CARD_ROW = { id: CARD_ID, service: "TROPICAL", name: "T", last4: null, priority: 3, monthly_limit_usd: "5000", active: false };
const patch = (body?: unknown) => post("/x", body, undefined, "PATCH");

describe("PATCH /api/inventario-usd/cards/[cardId]", () => {
  it("requires admin", async () => {
    const { PATCH } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await PATCH(patch({ active: false }), params(CARD_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("malformed id / empty body / service change -> 400, RPC never called", async () => {
    const { PATCH } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValue(c);
    expect((await PATCH(patch({ active: false }), params("nope"))).status).toBe(400);
    expect((await PATCH(patch({}), params(CARD_ID))).status).toBe(400);
    expect((await PATCH(patch({ service: "CLASICA" }), params(CARD_ID))).status).toBe(400);
    expect((await PATCH(post("/x", undefined, "{nope", "PATCH"), params(CARD_ID))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("sends only the named fields; the rest stay NULL", async () => {
    const { PATCH } = await import("./route");
    const c = ctx({ data: CARD_ROW, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await PATCH(patch({ priority: 3, active: false }), params(CARD_ID));

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_guardar_tarjeta_usd", {
      p_account_id: "account-a", p_card_id: CARD_ID, p_service: null, p_name: null, p_last4: null, p_priority: 3, p_monthly_limit_usd: null, p_active: false,
    });
    expect((await response.json()).card).toMatchObject({ id: CARD_ID, service: "TROPICAL", priority: 3, active: false });
  });

  it("last4 null clears the digits; unknown card -> 404", async () => {
    const { PATCH } = await import("./route");
    const c = ctx({ data: CARD_ROW, error: null });
    requireRole.mockResolvedValueOnce(c);
    await PATCH(patch({ last4: null }), params(CARD_ID));
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_guardar_tarjeta_usd", expect.objectContaining({ p_last4: "" }));

    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "P0002", message: "card not found" } }));
    expect((await PATCH(patch({ active: true }), params(CARD_ID))).status).toBe(404);
  });
});
