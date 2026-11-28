// Route-level tests for GET /api/remittance-operations/{operationId}/cup-plan
// (crm_inventario_cup_operacion, migration 241): agent+ only, operationId validation, the beta flag, RPC error mapping
// (42501/P0002 -> 403/404), the camelCase mapping and the "unknown payload" failure.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const OPERATION_ID = "11111111-1111-1111-1111-111111111111";
const ENABLED_PROFILE = { data: { beta_features: ["operations_panel"] }, error: null };
const DISABLED_PROFILE = { data: { beta_features: [] }, error: null };

function profileBuilder(result: { data: unknown; error: unknown }) {
  const builder = {
    select: vi.fn(() => builder),
    eq: vi.fn(() => builder),
    maybeSingle: vi.fn(() => Promise.resolve(result)),
  };
  return builder;
}

function ctx(profileResult: { data: unknown; error: unknown }, rpcResult: { data: unknown; error: unknown }) {
  const rpc = vi.fn(() => Promise.resolve(rpcResult));
  const from = vi.fn(() => profileBuilder(profileResult));
  return { supabase: { from, rpc }, userId: "user-a", accountId: "account-a", role: "agent" as const };
}

const request = (query = "") => new Request(`http://local/api/remittance-operations/${OPERATION_ID}/cup-plan${query}`);
const paramsFor = (operationId: string) => ({ params: Promise.resolve({ operationId }) });

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/remittance-operations/[operationId]/cup-plan", () => {
  it("requires the agent role: below agent -> 403, unauthenticated -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("agent");

    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(401);
  });

  it("malformed operationId -> 400 and the RPC is not called", async () => {
    const { GET } = await import("./route");
    const c = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await GET(request(), paramsFor("nope"))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("without the operations_panel flag -> 404 and the RPC is not called", async () => {
    const { GET } = await import("./route");
    const c = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(c);
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(404);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("maps RPC errors: 42501 -> 403, P0002 -> 404", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "42501", message: "x" } }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(403);
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "x" } }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(404);
  });

  it("an unexpected RPC error -> 500", async () => {
    const { GET } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "XX000", message: "boom" } }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(500);
  });

  it("returns the mapped plan, calls the RPC with the operation id, and is not cached", async () => {
    const { GET } = await import("./route");
    const c = ctx(ENABLED_PROFILE, {
      data: {
        state: "plan",
        total_cup: 50000,
        planned_cup: 50000,
        missing_cup: 0,
        cuba_day: "2026-10-15",
        effective_rate: 960,
        beneficiaries: [
          {
            beneficiary_id: "b1",
            position: 1,
            name: "Ana",
            amount_cup: 50000,
            missing_cup: 0,
            lines: [{ card_id: "A", card_name: "Tarjeta A", last4: "1111", lot_id: "l1", amount_cup: 50000, lot_rate: 960 }],
          },
        ],
      },
      error: null,
    });
    requireRole.mockResolvedValueOnce(c);

    const response = await GET(request(), paramsFor(OPERATION_ID));

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_inventario_cup_operacion", { p_operation_id: OPERATION_ID });
    const body = await response.json();
    expect(body.cupPlan.state).toBe("plan");
    expect(body.cupPlan.beneficiaries[0].lines[0]).toMatchObject({ cardName: "Tarjeta A", last4: "1111", amountCup: 50000 });
  });

  it("returns an empty state as is (the UI hides the block)", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: { state: "not_cup" }, error: null }));
    const response = await GET(request(), paramsFor(OPERATION_ID));
    expect(response.status).toBe(200);
    expect((await response.json()).cupPlan).toEqual({ state: "not_cup" });
  });

  it("a payload of an unknown shape -> 502 instead of passing it on", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: { state: "mystery" }, error: null }));
    expect((await GET(request(), paramsFor(OPERATION_ID))).status).toBe(502);
  });
});

describe("GET /api/remittance-operations/[operationId]/cup-plan: optional source card (migration 257)", () => {
  const CARD_ID = "22222222-2222-2222-2222-222222222222";
  const PLAN = {
    state: "plan", total_cup: 50000, planned_cup: 50000, missing_cup: 0, cuba_day: "2026-10-20", effective_rate: 1060, source_card_id: CARD_ID,
    cards: [{ id: CARD_ID, name: "Tarjeta B", last4: "2222", balance_cup: 250000, remaining_limit_today_cup: 120000 }],
    beneficiaries: [{ beneficiary_id: "b1", position: 1, name: "Ana", amount_cup: 50000, missing_cup: 0,
      lines: [{ card_id: CARD_ID, card_name: "Tarjeta B", last4: "2222", lot_id: "l1", amount_cup: 50000, lot_rate: 1060 }] }],
  };

  it("?card=<uuid> -> the RPC gets p_source_card_id and the picker's cards come back mapped", async () => {
    const { GET } = await import("./route");
    const c = ctx(ENABLED_PROFILE, { data: PLAN, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await GET(request(`?card=${CARD_ID}`), paramsFor(OPERATION_ID));

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_inventario_cup_operacion", { p_operation_id: OPERATION_ID, p_source_card_id: CARD_ID });
    const body = await response.json();
    expect(body.cupPlan.sourceCardId).toBe(CARD_ID);
    expect(body.cupPlan.cards).toEqual([
      { id: CARD_ID, name: "Tarjeta B", last4: "2222", balanceCup: 250000, remainingLimitTodayCup: 120000 },
    ]);
  });

  it("no ?card -> the RPC call is exactly the old one", async () => {
    const { GET } = await import("./route");
    const c = ctx(ENABLED_PROFILE, { data: { ...PLAN, source_card_id: null }, error: null });
    requireRole.mockResolvedValueOnce(c);

    await GET(request(), paramsFor(OPERATION_ID));

    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_inventario_cup_operacion", { p_operation_id: OPERATION_ID });
  });

  it("a malformed ?card -> 400 and the RPC is not called", async () => {
    const { GET } = await import("./route");
    const c = ctx(ENABLED_PROFILE, { data: PLAN, error: null });
    requireRole.mockResolvedValueOnce(c);

    expect((await GET(request("?card=nope"), paramsFor(OPERATION_ID))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("a card the RPC refuses (22023) -> 400", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: { code: "22023", message: "bad card" } }));
    expect((await GET(request(`?card=${CARD_ID}`), paramsFor(OPERATION_ID))).status).toBe(400);
  });
});
