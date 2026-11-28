// Route-level tests for POST
// /api/remittance-operations/beneficiaries/{beneficiaryId}/reassign.
// Covers auth gating, beneficiaryId and targetOperationId validation,
// the beta-flag 404, RPC error-code mapping (42501/22023/P0002 from
// crm_reasignar_beneficiario), and the happy-path response shape.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const USER_ID = "user-a";
const BENEFICIARY_ID = "22222222-2222-2222-2222-222222222222";
const TARGET_OPERATION_ID = "33333333-3333-3333-3333-333333333333";

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
    `http://local/api/remittance-operations/beneficiaries/${BENEFICIARY_ID}/reassign`,
    {
      method: "POST",
      body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
    },
  );
}

function paramsFor(beneficiaryId: string) {
  return { params: Promise.resolve({ beneficiaryId }) };
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/beneficiaries/[beneficiaryId]/reassign", () => {
  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(
      request({ targetOperationId: TARGET_OPERATION_ID }),
      paramsFor(BENEFICIARY_ID),
    );

    expect(response.status).toBe(401);
  });

  it("malformed beneficiaryId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(
      request({ targetOperationId: TARGET_OPERATION_ID }),
      paramsFor("not-a-uuid"),
    );

    expect(response.status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      request({ targetOperationId: TARGET_OPERATION_ID }),
      paramsFor(BENEFICIARY_ID),
    );

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(
      request(undefined, "{not-json"),
      paramsFor(BENEFICIARY_ID),
    );

    expect(response.status).toBe(400);
  });

  it("malformed targetOperationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(
      request({ targetOperationId: "not-a-uuid" }),
      paramsFor(BENEFICIARY_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("targetOperationId must be a UUID");
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "42501", message: "insufficient_privilege" },
      }),
    );

    const response = await POST(
      request({ targetOperationId: TARGET_OPERATION_ID }),
      paramsFor(BENEFICIARY_ID),
    );

    expect(response.status).toBe(403);
  });

  it("RPC validation error (22023) -> 400 with message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "22023", message: "target operation is closed" },
      }),
    );

    const response = await POST(
      request({ targetOperationId: TARGET_OPERATION_ID }),
      paramsFor(BENEFICIARY_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("target operation is closed");
  });

  it("RPC not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "not found" } }),
    );

    const response = await POST(
      request({ targetOperationId: TARGET_OPERATION_ID }),
      paramsFor(BENEFICIARY_ID),
    );

    expect(response.status).toBe(404);
  });

  it("success -> 200 { ok: true, id } and calls RPC with expected args", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: BENEFICIARY_ID, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      request({ targetOperationId: TARGET_OPERATION_ID }),
      paramsFor(BENEFICIARY_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toEqual({ ok: true, id: BENEFICIARY_ID });
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_reasignar_beneficiario", {
      p_beneficiary_id: BENEFICIARY_ID,
      p_target_operation_id: TARGET_OPERATION_ID,
    });
  });
});
