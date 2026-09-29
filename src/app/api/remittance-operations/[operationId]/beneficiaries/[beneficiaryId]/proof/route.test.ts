// Route-level tests for
// POST /api/remittance-operations/{operationId}/beneficiaries/{beneficiaryId}/proof.
// Covers auth gating, operationId/beneficiaryId validation, the beta-flag
// 404, JSON body validation (evidence shape/wamid/path/caption), RPC
// error-code mapping (P0002/42501/22023/40001 from
// crm_registrar_prueba_beneficiario), and the happy-path mapped response.

import { beforeEach, describe, expect, it } from "vitest";
import { vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const USER_ID = "user-a";
const OPERATION_ID = "11111111-1111-1111-1111-111111111111";
const BENEFICIARY_ID = "22222222-2222-2222-2222-222222222222";

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
    `http://local/api/remittance-operations/${OPERATION_ID}/beneficiaries/${BENEFICIARY_ID}/proof`,
    { method: "POST", body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)) },
  );
}

function paramsFor(operationId: string, beneficiaryId: string) {
  return { params: Promise.resolve({ operationId, beneficiaryId }) };
}

const VALID_EVIDENCE = {
  evidence: { wamid: "wamid.ABC", path: "account-1/x.png", caption: "Ana" },
};

const REGISTER_RPC_RESULT = { registered: true, missing: 1 };

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST .../beneficiaries/[beneficiaryId]/proof", () => {
  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID, BENEFICIARY_ID));

    expect(response.status).toBe(401);
  });

  it("malformed operationId -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_EVIDENCE), paramsFor("not-a-uuid", BENEFICIARY_ID));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("malformed beneficiaryId -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID, "not-a-uuid"));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID, BENEFICIARY_ID));

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(request(undefined, "{not-json"), paramsFor(OPERATION_ID, BENEFICIARY_ID));

    expect(response.status).toBe(400);
  });

  it.each([
    ["evidence missing", {}],
    ["evidence is an array", { evidence: [] }],
    ["evidence is null", { evidence: null }],
    ["evidence is a string", { evidence: "wamid.ABC" }],
    ["wamid missing", { evidence: {} }],
    ["wamid is an empty string", { evidence: { wamid: "" } }],
    ["wamid is not a string", { evidence: { wamid: 123 } }],
    ["wamid exceeds 500 characters", { evidence: { wamid: "a".repeat(501) } }],
    ["path is an empty string", { evidence: { wamid: "w", path: "" } }],
    ["path is not a string", { evidence: { wamid: "w", path: 123 } }],
    ["path exceeds 500 characters", { evidence: { wamid: "w", path: "a".repeat(501) } }],
    ["caption is not a string", { evidence: { wamid: "w", caption: 123 } }],
    ["caption exceeds 1024 characters", { evidence: { wamid: "w", caption: "a".repeat(1025) } }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(body), paramsFor(OPERATION_ID, BENEFICIARY_ID));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it.each([
    ["wamid alone", { evidence: { wamid: "w" } }],
    ["wamid + path", { evidence: { wamid: "w", path: "p" } }],
    ["wamid + caption", { evidence: { wamid: "w", caption: "Ana" } }],
    [
      "exactly 500-char wamid/path and 1024-char caption",
      { evidence: { wamid: "a".repeat(500), path: "b".repeat(500), caption: "c".repeat(1024) } },
    ],
  ])("%s is a valid evidence body -> RPC is called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: REGISTER_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(body), paramsFor(OPERATION_ID, BENEFICIARY_ID));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledTimes(1);
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "42501", message: "insufficient_privilege" } }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID, BENEFICIARY_ID));

    expect(response.status).toBe(403);
  });

  it("RPC not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "P0002", message: "operation not found" } }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID, BENEFICIARY_ID));

    expect(response.status).toBe(404);
  });

  it("RPC serialization failure (40001) -> 409", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "40001", message: "could not serialize access" } }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID, BENEFICIARY_ID));
    const body = await response.json();

    expect(response.status).toBe(409);
    expect(body.error).toBe("Operation changed concurrently, retry");
  });

  it("RPC validation error (22023) -> 400 with message — e.g. 'not a current beneficiary'", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "22023", message: "beneficiary is not a current beneficiary of this operation" },
      }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID, BENEFICIARY_ID));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("beneficiary is not a current beneficiary of this operation");
  });

  it("unmapped RPC error code -> throws / 500", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "XXXXX", message: "unexpected" } }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID, BENEFICIARY_ID));

    expect(response.status).toBe(500);
  });

  it("success -> 200 { ok: true, registered, missing } and calls RPC with operationId/beneficiaryId/evidence", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: REGISTER_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID, BENEFICIARY_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_registrar_prueba_beneficiario", {
      p_operation_id: OPERATION_ID,
      p_beneficiary_id: BENEFICIARY_ID,
      p_evidence: { wamid: "wamid.ABC", path: "account-1/x.png", caption: "Ana" },
    });
    expect(body).toEqual({ ok: true, registered: true, missing: 1 });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("strips unknown keys from evidence before calling the RPC", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: REGISTER_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      request({ evidence: { wamid: "w", extra: "ignored" } }),
      paramsFor(OPERATION_ID, BENEFICIARY_ID),
    );

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_registrar_prueba_beneficiario", {
      p_operation_id: OPERATION_ID,
      p_beneficiary_id: BENEFICIARY_ID,
      p_evidence: { wamid: "w" },
    });
  });
});
