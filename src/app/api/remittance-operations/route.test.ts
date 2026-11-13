// Route-level tests for GET /api/remittance-operations. Covers auth
// gating, conversationId validation, the beta-flag 404 (design decision
// 8: gate is UI + API, never just the UI), the 42501 -> 403 mapping from
// the RPC's own authorization, and the happy-path read-model shape.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const USER_ID = "user-a";

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
  return { supabase: { from, rpc }, userId: USER_ID, accountId: "account-a", role: "viewer" as const, account: { id: "account-a", name: "A" } };
}

function request(conversationId?: string) {
  const url = conversationId
    ? `http://local/api/remittance-operations?conversationId=${conversationId}`
    : "http://local/api/remittance-operations";
  return new Request(url);
}

const CONVERSATION_ID = "11111111-1111-1111-1111-111111111111";

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/remittance-operations", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await GET(request(CONVERSATION_ID));

    expect(response.status).toBe(401);
  });

  it("missing conversationId -> 400", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: { beta_features: ["operations_panel"] }, error: null }, { data: [], error: null }));

    const response = await GET(request());

    expect(response.status).toBe(400);
  });

  it("malformed conversationId -> 400", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: { beta_features: ["operations_panel"] }, error: null }, { data: [], error: null }));

    const response = await GET(request("not-a-uuid"));

    expect(response.status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { GET } = await import("./route");
    const callCtx = ctx({ data: { beta_features: [] }, error: null }, { data: [], error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request(CONVERSATION_ID));

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(
        { data: { beta_features: ["operations_panel"] }, error: null },
        { data: null, error: { code: "42501", message: "insufficient_privilege" } },
      ),
    );

    const response = await GET(request(CONVERSATION_ID));

    expect(response.status).toBe(403);
  });

  it("beta flag enabled -> calls the RPC and returns the mapped read model", async () => {
    const { GET } = await import("./route");
    const rows = [
      {
        resolver_resultado: "unica",
        resolver_operation_id: "op-1",
        resolver_candidatas: 1,
        operation_id: "op-1",
        operation_status: "ready_to_transfer",
        operation_service_type: "remesa",
        operation_source_currency: "GYD",
        operation_destination_currency: null,
        operation_delivery_method: null,
        operation_deposit_method: null,
        operation_quoted_source_amount: 5000,
        operation_quoted_destination_amount: null,
        operation_admin_locked_fields: {},
        operation_created_at: "2026-09-14T00:00:00Z",
        operation_completed_at: null,
        beneficiary_id: "ben-1",
        beneficiary_type: "cuban_card",
        beneficiary_name: "Solo Beneficiario",
        beneficiary_card_number: "9205123412349412",
        beneficiary_phone: null,
        beneficiary_zelle_account: null,
        beneficiary_delivery_method: null,
        beneficiary_amount: null,
        beneficiary_currency: null,
        beneficiary_position: 1,
      },
    ];
    const callCtx = ctx({ data: { beta_features: ["operations_panel"] }, error: null }, { data: rows, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request(CONVERSATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_operaciones_de_conversacion", {
      p_conversation_id: CONVERSATION_ID,
    });
    expect(body.resolverState).toBe("unica");
    expect(body.operations).toHaveLength(1);
    // Full card number is intentionally sent to the client (product
    // decision: operators need to copy it, and it already appears in the
    // conversation thread on this screen).
    expect(body.operations[0].beneficiaries[0].cardNumber).toBe("9205123412349412");
  });
});

// Slice: panel-26 (readiness). The route now composes a second reader on
// top of `mapRemittanceOperationsRows` — one `crm_comprobantes_de_operacion`
// call per operation, issued in parallel, so the client paints the deposit
// block in the same round trip instead of a second waterfall step.

function operationRow(id: string, overrides: Record<string, unknown> = {}) {
  return {
    resolver_resultado: "unica",
    resolver_operation_id: id,
    resolver_candidatas: 1,
    operation_id: id,
    operation_status: "deposit_verification",
    operation_service_type: "remesa",
    operation_source_currency: "GYD",
    operation_destination_currency: null,
    operation_delivery_method: null,
    operation_deposit_method: null,
    operation_quoted_source_amount: 5000,
    operation_quoted_destination_amount: null,
    operation_admin_locked_fields: {},
    operation_created_at: "2026-09-14T00:00:00Z",
    operation_completed_at: null,
    beneficiary_id: null,
    beneficiary_type: null,
    beneficiary_name: null,
    beneficiary_card_number: null,
    beneficiary_phone: null,
    beneficiary_zelle_account: null,
    beneficiary_delivery_method: null,
    beneficiary_amount: null,
    beneficiary_currency: null,
    beneficiary_position: null,
    ...overrides,
  };
}

function receiptsPayload(operationId: string, overrides: Record<string, unknown> = {}) {
  return {
    operation_id: operationId,
    status: "deposit_verification",
    deal_id: `deal-${operationId}`,
    can_verify: true,
    objetivo: 25000,
    depositado: 0,
    saldo: 25000,
    moneda: "GYD",
    receipts: [],
    consumed_deposits: [],
    ...overrides,
  };
}

function multiRpcCtx(
  profileResult: { data: unknown; error: unknown },
  rows: unknown[],
  receiptsImpl: (operationId: string) => Promise<{ data: unknown; error: unknown }>,
) {
  const rpc = vi.fn((name: string, args: Record<string, unknown>) => {
    if (name === "crm_operaciones_de_conversacion") {
      return Promise.resolve({ data: rows, error: null });
    }
    if (name === "crm_comprobantes_de_operacion") {
      return receiptsImpl(args.p_operation_id as string);
    }
    throw new Error(`unexpected rpc: ${name}`);
  });
  const from = vi.fn(() => profileBuilder(profileResult));
  return { supabase: { from, rpc }, userId: USER_ID, accountId: "account-a", role: "viewer" as const, account: { id: "account-a", name: "A" } };
}

describe("GET /api/remittance-operations — receipts prefetch", () => {
  it("also fetches each operation's receipts and includes them keyed by operation id", async () => {
    const { GET } = await import("./route");
    const rows = [operationRow("op-1"), operationRow("op-2")];
    const callCtx = multiRpcCtx(
      { data: { beta_features: ["operations_panel"] }, error: null },
      rows,
      (operationId) => Promise.resolve({ data: receiptsPayload(operationId), error: null }),
    );
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await GET(request(CONVERSATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.operations).toHaveLength(2);
    expect(body.receiptsByOperationId["op-1"].dealId).toBe("deal-op-1");
    expect(body.receiptsByOperationId["op-2"].dealId).toBe("deal-op-2");
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_comprobantes_de_operacion", {
      p_operation_id: "op-1",
    });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_comprobantes_de_operacion", {
      p_operation_id: "op-2",
    });
  });

  it("a receipts RPC that rejects for one operation still returns 200 with the other operation's receipts present and that one absent", async () => {
    const { GET } = await import("./route");
    const rows = [operationRow("op-1"), operationRow("op-2")];
    const callCtx = multiRpcCtx(
      { data: { beta_features: ["operations_panel"] }, error: null },
      rows,
      (operationId) =>
        operationId === "op-1"
          ? Promise.resolve({ data: null, error: { code: "XX000", message: "boom" } })
          : Promise.resolve({ data: receiptsPayload(operationId), error: null }),
    );
    requireRole.mockResolvedValueOnce(callCtx);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const response = await GET(request(CONVERSATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.receiptsByOperationId["op-1"]).toBeUndefined();
    expect(body.receiptsByOperationId["op-2"]).toBeDefined();
    expect(errorSpy).toHaveBeenCalled();
    errorSpy.mockRestore();
  });

  it("a receipts RPC that THROWS for one operation still returns 200, same as one that returns an error", async () => {
    // The case above covers an `{ error }` return, which is how Supabase
    // reports a query failure. A transport failure rejects instead, and an
    // unhandled rejection here would take the whole panel down with it —
    // the one thing the prefetch must never do, since it is a convenience
    // and the client can still fetch receipts itself.
    const { GET } = await import("./route");
    const rows = [operationRow("op-1"), operationRow("op-2")];
    const callCtx = multiRpcCtx(
      { data: { beta_features: ["operations_panel"] }, error: null },
      rows,
      (operationId) =>
        operationId === "op-1"
          ? Promise.reject(new Error("network down"))
          : Promise.resolve({ data: receiptsPayload(operationId), error: null }),
    );
    requireRole.mockResolvedValueOnce(callCtx);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const response = await GET(request(CONVERSATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.receiptsByOperationId["op-1"]).toBeUndefined();
    expect(body.receiptsByOperationId["op-2"]).toBeDefined();
    expect(errorSpy).toHaveBeenCalled();
    errorSpy.mockRestore();
  });

  it("issues every operation's receipts RPC call before any of them resolves (parallel, not sequential)", async () => {
    const { GET } = await import("./route");
    const rows = [operationRow("op-1"), operationRow("op-2")];
    const issued: string[] = [];
    const resolvers: Record<string, (value: { data: unknown; error: unknown }) => void> = {};
    const callCtx = multiRpcCtx(
      { data: { beta_features: ["operations_panel"] }, error: null },
      rows,
      (operationId) => {
        issued.push(operationId);
        return new Promise((resolve) => {
          resolvers[operationId] = resolve;
        });
      },
    );
    requireRole.mockResolvedValueOnce(callCtx);

    const responsePromise = GET(request(CONVERSATION_ID));
    // Let the microtask queue drain enough for both RPC calls to be
    // issued, without letting either of their promises resolve yet —
    // several awaits (requireRole, the profile read, the operations RPC)
    // sit ahead of the receipts calls in route.ts, each needing its own
    // microtask tick, so this drains generously rather than guessing an
    // exact count.
    for (let i = 0; i < 20 && issued.length < 2; i++) {
      await Promise.resolve();
    }

    expect(issued.sort()).toEqual(["op-1", "op-2"]);

    resolvers["op-1"]!({ data: receiptsPayload("op-1"), error: null });
    resolvers["op-2"]!({ data: receiptsPayload("op-2"), error: null });

    const response = await responsePromise;
    expect(response.status).toBe(200);
  });
});

// The bot's current quote rides along as `quote`. It is a convenience read:
// a failing/missing quote function must never cost the operations panel.
describe("GET /api/remittance-operations — quote", () => {
  const QUOTE_ROW = { gyd: "5000", destino_monto: "15000", destino_moneda: "CUP", cotizado_en: "2026-10-02T10:00:00Z" };

  function quoteCtx(quoteImpl: () => Promise<{ data: unknown; error: unknown }>) {
    const rpc = vi.fn((name: string) => {
      if (name === "crm_operaciones_de_conversacion") {
        return Promise.resolve({ data: [operationRow("op-1")], error: null });
      }
      if (name === "crm_comprobantes_de_operacion") {
        return Promise.resolve({ data: receiptsPayload("op-1"), error: null });
      }
      if (name === "crm_cotizacion_de_conversacion") return quoteImpl();
      throw new Error(`unexpected rpc: ${name}`);
    });
    const from = vi.fn(() => profileBuilder({ data: { beta_features: ["operations_panel"] }, error: null }));
    return { supabase: { from, rpc }, userId: USER_ID, accountId: "account-a", role: "viewer" as const, account: { id: "account-a", name: "A" } };
  }

  it("returns the mapped quote and asks for the same conversation", async () => {
    const { GET } = await import("./route");
    const callCtx = quoteCtx(() => Promise.resolve({ data: [QUOTE_ROW], error: null }));
    requireRole.mockResolvedValueOnce(callCtx);

    const body = await (await GET(request(CONVERSATION_ID))).json();

    expect(body.quote).toEqual({
      gyd: 5000,
      destinationAmount: 15000,
      destinationCurrency: "CUP",
      quotedAt: "2026-10-02T10:00:00Z",
    });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_cotizacion_de_conversacion", {
      p_conversation_id: CONVERSATION_ID,
    });
  });

  it("quote is null when the function returns no row", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(quoteCtx(() => Promise.resolve({ data: [], error: null })));

    const body = await (await GET(request(CONVERSATION_ID))).json();

    expect(body.quote).toBeNull();
  });

  it("an error from the quote RPC still returns the operations with quote null", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      quoteCtx(() => Promise.resolve({ data: null, error: { code: "42883", message: "function does not exist" } })),
    );
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const response = await GET(request(CONVERSATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.operations).toHaveLength(1);
    expect(body.quote).toBeNull();
    expect(errorSpy).toHaveBeenCalled();
    errorSpy.mockRestore();
  });

  it("a quote RPC that throws still returns the operations with quote null", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(quoteCtx(() => Promise.reject(new Error("network down"))));
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const response = await GET(request(CONVERSATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.operations).toHaveLength(1);
    expect(body.quote).toBeNull();
    errorSpy.mockRestore();
  });
});

// A split planned before the deposit rides along as `plannedSplit` (migration 370). Convenience data: never fatal.
describe("GET /api/remittance-operations — planned split", () => {
  const PLAN_ROWS = [
    { servicio: "recarga", monto_gyd: "12400", posicion: 1, total_gyd: "25400" },
    { servicio: "zelle", monto_gyd: "13000", posicion: 2, total_gyd: "25400" },
  ];

  function planCtx(planImpl: () => Promise<{ data: unknown; error: unknown }>) {
    const rpc = vi.fn((name: string) => {
      if (name === "crm_operaciones_de_conversacion") return Promise.resolve({ data: [operationRow("op-1")], error: null });
      if (name === "crm_comprobantes_de_operacion") return Promise.resolve({ data: receiptsPayload("op-1"), error: null });
      if (name === "crm_cotizacion_de_conversacion") return Promise.resolve({ data: [], error: null });
      if (name === "crm_reparto_planeado_de_conversacion") return planImpl();
      throw new Error(`unexpected rpc: ${name}`);
    });
    const from = vi.fn(() => profileBuilder({ data: { beta_features: ["operations_panel"] }, error: null }));
    return { supabase: { from, rpc }, userId: USER_ID, accountId: "account-a", role: "viewer" as const, account: { id: "account-a", name: "A" } };
  }

  it("returns the mapped plan and asks for the same conversation", async () => {
    const { GET } = await import("./route");
    const callCtx = planCtx(() => Promise.resolve({ data: PLAN_ROWS, error: null }));
    requireRole.mockResolvedValueOnce(callCtx);

    const body = await (await GET(request(CONVERSATION_ID))).json();

    expect(body.plannedSplit).toEqual({
      totalGyd: 25400,
      parts: [
        { service: "recarga", amountGyd: 12400 },
        { service: "zelle", amountGyd: 13000 },
      ],
    });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_reparto_planeado_de_conversacion", { p_conversation_id: CONVERSATION_ID });
  });

  it("plannedSplit is null when there is no plan, and a failing read still returns the operations", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(planCtx(() => Promise.resolve({ data: [], error: null })));
    expect((await (await GET(request(CONVERSATION_ID))).json()).plannedSplit).toBeNull();

    requireRole.mockResolvedValueOnce(planCtx(() => Promise.resolve({ data: null, error: { code: "42883", message: "function does not exist" } })));
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await GET(request(CONVERSATION_ID));
    const body = await response.json();
    expect(response.status).toBe(200);
    expect(body.operations).toHaveLength(1);
    expect(body.plannedSplit).toBeNull();
    errorSpy.mockRestore();
  });
});
