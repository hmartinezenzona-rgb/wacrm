// Route-level tests for POST /api/remittance-operations/{operationId}/deliver.
// Covers auth gating, operationId validation, the beta-flag 404, JSON body
// validation (evidence shape/mode/wamid/path), RPC error-code mapping
// (42501/22023/40001 from crm_entregar_operacion), and the happy-path
// mapped response shape.

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
  return new Request(`http://local/api/remittance-operations/${OPERATION_ID}/deliver`, {
    method: "POST",
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

function paramsFor(operationId: string) {
  return { params: Promise.resolve({ operationId }) };
}

const VALID_EVIDENCE = { evidence: { mode: "proof_sent", wamid: "wamid.ABC", path: "account-1/x.png" } };

const DELIVER_RPC_RESULT = {
  new_status: "completed",
  completed_at: "2026-09-15T12:00:00Z",
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/deliver", () => {
  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID));

    expect(response.status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(request(VALID_EVIDENCE), paramsFor("not-a-uuid"));

    expect(response.status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID));

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
    ["evidence missing", {}],
    ["evidence is an array", { evidence: [] }],
    ["evidence is null", { evidence: null }],
    ["evidence is a string", { evidence: "proof_sent" }],
    ["mode missing", { evidence: {} }],
    ["mode is not one of the three values", { evidence: { mode: "sent" } }],
    ["mode is not a string", { evidence: { mode: 1 } }],
    ["wamid is an empty string", { evidence: { mode: "proof_sent", wamid: "" } }],
    ["wamid is not a string", { evidence: { mode: "proof_sent", wamid: 123 } }],
    ["wamid exceeds 500 characters", { evidence: { mode: "proof_sent", wamid: "a".repeat(501) } }],
    ["path is an empty string", { evidence: { mode: "proof_sent", path: "" } }],
    ["path is not a string", { evidence: { mode: "proof_sent", path: 123 } }],
    ["path exceeds 500 characters", { evidence: { mode: "proof_sent", path: "a".repeat(501) } }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(body), paramsFor(OPERATION_ID));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it.each([
    ["no_proof", { evidence: { mode: "no_proof" } }],
    ["skip_proof", { evidence: { mode: "skip_proof" } }],
    ["proof_sent with exactly 500-char wamid and path", {
      evidence: { mode: "proof_sent", wamid: "a".repeat(500), path: "b".repeat(500) },
    }],
  ])("%s is a valid evidence body -> RPC is called", async (_label, body) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: DELIVER_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(body), paramsFor(OPERATION_ID));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledTimes(1);
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "42501", message: "insufficient_privilege" },
      }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID));

    expect(response.status).toBe(403);
  });

  it("RPC not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "P0002", message: "operation not found" },
      }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID));

    expect(response.status).toBe(404);
  });

  it("RPC serialization failure (40001) -> 409", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "40001", message: "could not serialize access" },
      }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(409);
    expect(body.error).toBe("Operation changed concurrently, retry");
  });

  it("RPC validation error (22023) -> 400 with message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "22023", message: "operation is not ready to transfer" },
      }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("operation is not ready to transfer");
  });

  it("unmapped RPC error code -> throws / 500", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "XXXXX", message: "unexpected" },
      }),
    );

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID));

    expect(response.status).toBe(500);
  });

  it("success -> 200 { ok: true, newStatus, completedAt } and calls RPC with operationId and evidence", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: DELIVER_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request(VALID_EVIDENCE), paramsFor(OPERATION_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_entregar_operacion", {
      p_operation_id: OPERATION_ID,
      p_evidence: { mode: "proof_sent", wamid: "wamid.ABC", path: "account-1/x.png" },
      p_notify: true,
    });
    expect(body).toEqual({ ok: true, newStatus: "completed", completedAt: "2026-09-15T12:00:00Z" });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("strips unknown keys from evidence before calling the RPC", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: DELIVER_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      request({ evidence: { mode: "no_proof", extra: "ignored" } }),
      paramsFor(OPERATION_ID),
    );

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_entregar_operacion", {
      p_operation_id: OPERATION_ID,
      p_evidence: { mode: "no_proof" },
      p_notify: true,
    });
  });

  it("notify:false in the body -> RPC gets p_notify false", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: DELIVER_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      request({ ...VALID_EVIDENCE, notify: false }),
      paramsFor(OPERATION_ID),
    );

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_entregar_operacion", {
      p_operation_id: OPERATION_ID,
      p_evidence: { mode: "proof_sent", wamid: "wamid.ABC", path: "account-1/x.png" },
      p_notify: false,
    });
  });

  it("notify not a boolean -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      request({ ...VALID_EVIDENCE, notify: "yes" }),
      paramsFor(OPERATION_ID),
    );

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });
});

describe("POST /api/remittance-operations/[operationId]/deliver: optional CUP source card (migration 257)", () => {
  const CARD_ID = "22222222-2222-2222-2222-222222222222";

  it("cupSourceCardId in the body -> the RPC gets p_cup_source_card_id", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: DELIVER_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ ...VALID_EVIDENCE, cupSourceCardId: CARD_ID }), paramsFor(OPERATION_ID));

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_entregar_operacion", {
      p_operation_id: OPERATION_ID,
      p_evidence: { mode: "proof_sent", wamid: "wamid.ABC", path: "account-1/x.png" },
      p_notify: true,
      p_cup_source_card_id: CARD_ID,
    });
  });

  it.each([
    ["absent", undefined],
    ["null", null],
  ])("cupSourceCardId %s -> the RPC call has no p_cup_source_card_id key (priority allocation, old call shape)", async (_label, value) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: DELIVER_RPC_RESULT, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ ...VALID_EVIDENCE, cupSourceCardId: value }), paramsFor(OPERATION_ID));

    expect(response.status).toBe(200);
    const args = (callCtx.supabase.rpc.mock.calls[0] as unknown[])[1] as Record<string, unknown>;
    expect("p_cup_source_card_id" in args).toBe(false);
  });

  it.each([["not-a-uuid"], [42], [""], [{}]])("cupSourceCardId %j -> 400 and the RPC is never called", async (value) => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(request({ ...VALID_EVIDENCE, cupSourceCardId: value }), paramsFor(OPERATION_ID));

    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("a card the RPC refuses (22023) -> 400 with its message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, { data: null, error: { code: "22023", message: "the CUP source card must be one of the account's active cards" } }),
    );

    const response = await POST(request({ ...VALID_EVIDENCE, cupSourceCardId: CARD_ID }), paramsFor(OPERATION_ID));

    expect(response.status).toBe(400);
    expect((await response.json()).error).toContain("active cards");
  });
});
