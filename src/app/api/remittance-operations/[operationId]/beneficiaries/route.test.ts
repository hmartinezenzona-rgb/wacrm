// Route-level tests for POST /api/remittance-operations/{operationId}/beneficiaries.
// Covers auth gating, operationId validation, the beta-flag 404, JSON body
// validation (datos must be a non-empty object), RPC error-code mapping
// (42501/22023/P0002/40001 from crm_agregar_beneficiario), and the
// happy-path mapped response shape (id + refreshed completeness).

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
  return new Request(
    `http://local/api/remittance-operations/${OPERATION_ID}/beneficiaries`,
    {
      method: "POST",
      body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
    },
  );
}

function paramsFor(operationId: string) {
  return { params: Promise.resolve({ operationId }) };
}

const VALID_DATOS = {
  datos: {
    beneficiary_type: "cuban_card",
    card_number: "9205123412349412",
    phone: "55512345",
    amount: 15000,
    currency: "CUP",
  },
};

const NEW_BENEFICIARY_ID = "22222222-2222-2222-2222-222222222222";
const AGREGAR_RPC_RESULT = { id: NEW_BENEFICIARY_ID, complete: true };

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/beneficiaries", () => {
  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(request(VALID_DATOS), paramsFor(OPERATION_ID));

    expect(response.status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(request(VALID_DATOS), paramsFor("not-a-uuid"));

    expect(response.status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_DATOS), paramsFor(OPERATION_ID));

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
    ["datos missing", {}],
    ["datos is an array", { datos: [] }],
    ["datos is null", { datos: null }],
    ["datos is a string", { datos: "cuban_card" }],
    ["datos is an empty object", { datos: {} }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(body), paramsFor(OPERATION_ID));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "42501", message: "insufficient_privilege" },
      }),
    );

    const response = await POST(request(VALID_DATOS), paramsFor(OPERATION_ID));

    expect(response.status).toBe(403);
  });

  it("RPC not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "operation not found" } }),
    );

    const response = await POST(request(VALID_DATOS), paramsFor(OPERATION_ID));

    expect(response.status).toBe(404);
  });

  it("RPC validation error (22023) -> 400 with message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "22023", message: "card_number must be exactly 16 digits" },
      }),
    );

    const response = await POST(request(VALID_DATOS), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("card_number must be exactly 16 digits");
  });

  it("RPC serialization failure (40001) -> 409", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "40001", message: "could not serialize access" },
      }),
    );

    const response = await POST(request(VALID_DATOS), paramsFor(OPERATION_ID));

    expect(response.status).toBe(409);
  });

  it("unmapped RPC error code -> throws / 500", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "XXXXX", message: "unexpected" } }),
    );

    const response = await POST(request(VALID_DATOS), paramsFor(OPERATION_ID));

    expect(response.status).toBe(500);
  });

  it("success -> 200 { ok: true, id, complete } and calls RPC with operationId and datos", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: AGREGAR_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_DATOS), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_agregar_beneficiario", {
      p_operation_id: OPERATION_ID,
      p_datos: VALID_DATOS.datos,
    });
    expect(body).toEqual({ ok: true, id: NEW_BENEFICIARY_ID, complete: true });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });
});
