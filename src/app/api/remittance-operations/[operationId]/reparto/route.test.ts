// Route-level tests for POST /api/remittance-operations/{operationId}/reparto.
// Covers auth gating, operationId validation, the beta-flag 404, body validation
// (partes must be an array of at least two objects), RPC error-code mapping
// (42501/22023/P0002/40001 from crm_editar_reparto), the Spanish translation of
// the known 22023 messages and the happy-path response shape.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const USER_ID = "user-a";
const OPERATION_ID = "11111111-1111-1111-1111-111111111111";
const SHARE_A = "22222222-2222-2222-2222-222222222222";
const SHARE_B = "33333333-3333-3333-3333-333333333333";
const SHARE_C = "44444444-4444-4444-4444-444444444444";

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

function ctx(
  profileResult: { data: unknown; error: unknown },
  rpcResult: { data: unknown; error: unknown },
) {
  const rpc = vi.fn(() => Promise.resolve(rpcResult));
  const from = vi.fn(() => profileBuilder(profileResult));
  return {
    supabase: { from, rpc },
    userId: USER_ID,
    accountId: "account-a",
    role: "agent" as const,
    account: { id: "account-a", name: "A" },
  };
}

function request(body?: unknown, rawBody?: string) {
  return new Request(`http://local/api/remittance-operations/${OPERATION_ID}/reparto`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

function paramsFor(operationId: string) {
  return { params: Promise.resolve({ operationId }) };
}

const VALID_BODY = {
  partes: [
    {
      id: SHARE_A,
      beneficiary_type: "cuban_card",
      name: "Persona Uno",
      card_number: "9205000000000001",
      phone: "55500001",
      amount: 10000,
      currency: "CUP",
    },
    {
      id: null,
      beneficiary_type: "cuban_card",
      name: "Persona Dos",
      card_number: "9205000000000002",
      phone: null,
      amount: 5000,
      currency: "CUP",
    },
  ],
};

const RPC_RESULT = { operation_id: OPERATION_ID, retired: [SHARE_B], created: [SHARE_C], kept: [SHARE_A], complete: true };

function rpcFailure(code: string, message: string) {
  return ctx(ENABLED_PROFILE, { data: null, error: { code, message } });
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/reparto", () => {
  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(request(VALID_BODY), paramsFor(OPERATION_ID));

    expect(response.status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(request(VALID_BODY), paramsFor("not-a-uuid"));

    expect(response.status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_BODY), paramsFor(OPERATION_ID));

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(request(undefined, "{not-json"), paramsFor(OPERATION_ID));

    expect(response.status).toBe(400);
  });

  it.each([
    ["partes missing", {}],
    ["partes is not an array", { partes: "x" }],
    ["partes has one share", { partes: [VALID_BODY.partes[0]] }],
    ["a share is not an object", { partes: [VALID_BODY.partes[0], "x"] }],
    ["a share is an array", { partes: [VALID_BODY.partes[0], []] }],
    ["a share is null", { partes: [VALID_BODY.partes[0], null] }],
  ])("%s -> 400 in Spanish, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(body), paramsFor(OPERATION_ID));
    const json = await response.json();

    expect(response.status).toBe(400);
    expect(json.error).toMatch(/al menos 2 partes/);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC insufficient_privilege (42501) -> 403 in Spanish", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      rpcFailure("42501", "not authorized to edit the split of this operation"),
    );

    const response = await POST(request(VALID_BODY), paramsFor(OPERATION_ID));
    const json = await response.json();

    expect(response.status).toBe(403);
    expect(json.error).toBe("No tienes permiso para editar el reparto de esta operación");
  });

  it("RPC not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(rpcFailure("P0002", "operation not found"));

    const response = await POST(request(VALID_BODY), paramsFor(OPERATION_ID));

    expect(response.status).toBe(404);
  });

  it("RPC serialization failure (40001) -> 409", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(rpcFailure("40001", "could not serialize access"));

    const response = await POST(request(VALID_BODY), paramsFor(OPERATION_ID));

    expect(response.status).toBe(409);
  });

  it("unmapped RPC error code -> 500", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(rpcFailure("XXXXX", "unexpected"));

    const response = await POST(request(VALID_BODY), paramsFor(OPERATION_ID));

    expect(response.status).toBe(500);
  });

  it.each([
    ["operation is closed", "La operación está cerrada"],
    ["the split can only be edited on a remesa operation", "El reparto solo se puede editar en una operación de remesa"],
    ["a split needs at least 2 shares", "Un reparto necesita al menos 2 partes"],
    [
      "the operation has no destination total: set the total first",
      "La operación no tiene total de destino: corrige el total primero",
    ],
    [
      "the operation has no destination currency: set it first",
      "La operación no tiene moneda de destino: defínela primero",
    ],
    [
      "the operation has a zelle recipient: only card splits can be edited here",
      "La operación tiene un destinatario zelle: aquí solo se puede editar el reparto por tarjeta",
    ],
    ["share 2: unknown field: foo", "Parte 2: campo desconocido «foo»"],
    ["share 1: the same share is listed twice", "Parte 1: el mismo destinatario está repetido"],
    ["share 3: beneficiary does not belong to this operation or is not current", "Parte 3: ese destinatario no pertenece a la operación o ya no está vigente"],
    ["share 2: invalid beneficiary_type: x (a split takes card rails only)", "Parte 2: tipo de destinatario no válido (un reparto solo admite tarjetas)"],
    ["share 4 must be a JSON object", "Parte 4: formato no válido"],
    ["share 2: id must be a uuid or null", "Parte 2: identificador no válido"],
    ["partes must be a JSON array of shares", "Las partes deben ser una lista"],
    ["share 2: card_number must be exactly 16 digits", "Parte 2: la tarjeta debe tener exactamente 16 dígitos"],
    ["share 1: phone must be 8 to 15 digits", "Parte 1: el teléfono debe tener entre 8 y 15 dígitos"],
    ["share 2: amount is required and must be greater than 0", "Parte 2: el monto es obligatorio y debe ser mayor que cero"],
    [
      "share 1: currency USD does not match the operation's destination currency CUP",
      "Parte 1: la moneda USD no coincide con la de la operación (CUP)",
    ],
    [
      "the shares add up to 14000 but the operation total is 15000 (difference 1000)",
      "Las partes suman 14000 pero el total de la operación es 15000 (diferencia 1000)",
    ],
    [
      "the shares add up to 16000.5 but the operation total is 15000 (difference -1000.5)",
      "Las partes suman 16000.5 pero el total de la operación es 15000 (diferencia -1000.5)",
    ],
  ])("22023 %s -> 400 translated", async (message, expected) => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(rpcFailure("22023", message));

    const response = await POST(request(VALID_BODY), paramsFor(OPERATION_ID));
    const json = await response.json();

    expect(response.status).toBe(400);
    expect(json.error).toBe(expected);
  });

  it("22023 with an unknown message -> 400 keeping the original message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(rpcFailure("22023", "something new"));

    const response = await POST(request(VALID_BODY), paramsFor(OPERATION_ID));
    const json = await response.json();

    expect(response.status).toBe(400);
    expect(json.error).toBe("something new");
  });

  it("success -> 200 with the RPC summary and calls the RPC with operationId and partes", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_BODY), paramsFor(OPERATION_ID));
    const json = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_editar_reparto", {
      p_operation_id: OPERATION_ID,
      p_partes: VALID_BODY.partes,
    });
    expect(json).toEqual({ ok: true, retired: [SHARE_B], created: [SHARE_C], kept: [SHARE_A], complete: true });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });
});
