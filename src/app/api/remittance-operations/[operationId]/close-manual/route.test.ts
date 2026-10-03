// Route-level tests for POST /api/remittance-operations/{operationId}/close-manual.
// Covers admin-only role gating (requireRole("admin") itself rejects lower
// roles by throwing, so we assert on requireRole's rejection like the
// pattern routes), operationId validation, the beta-flag 404, reason
// validation, RPC error-code mapping (42501/40001), and the happy-path
// response shape.

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
    role: "admin" as const,
    account: { id: "account-a", name: "A" },
  };
}

function request(body?: unknown, rawBody?: string) {
  return new Request(
    `http://local/api/remittance-operations/${OPERATION_ID}/close-manual`,
    {
      method: "POST",
      body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
    },
  );
}

function paramsFor(operationId: string) {
  return { params: Promise.resolve({ operationId }) };
}

const VALID_REASON = "Customer never sent the card phone, owner transferred";

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/remittance-operations/[operationId]/close-manual", () => {
  it("caller below admin -> role rejected by requireRole", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });

    const response = await POST(
      request({ reason: VALID_REASON }),
      paramsFor(OPERATION_ID),
    );

    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("unauthenticated request -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await POST(
      request({ reason: VALID_REASON }),
      paramsFor(OPERATION_ID),
    );

    expect(response.status).toBe(401);
  });

  it("malformed operationId -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(
      request({ reason: VALID_REASON }),
      paramsFor("not-a-uuid"),
    );

    expect(response.status).toBe(400);
  });

  it("caller without the operations_panel beta flag -> 404, RPC never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(DISABLED_PROFILE, { data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      request({ reason: VALID_REASON }),
      paramsFor(OPERATION_ID),
    );

    expect(response.status).toBe(404);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx(ENABLED_PROFILE, { data: null, error: null }));

    const response = await POST(
      request(undefined, "{not-json"),
      paramsFor(OPERATION_ID),
    );

    expect(response.status).toBe(400);
  });

  it.each([
    ["reason missing", {}],
    ["reason too long", { reason: "x".repeat(501) }],
    ["reason blank after trim", { reason: "    " }],
    ["reason not a string", { reason: 12345 }],
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

    const response = await POST(
      request({ reason: VALID_REASON }),
      paramsFor(OPERATION_ID),
    );

    expect(response.status).toBe(403);
  });

  it("RPC invalid_parameter_value (22023) -> 400 with the RPC message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "22023", message: "operation status does not allow this" },
      }),
    );

    const response = await POST(
      request({ reason: VALID_REASON }),
      paramsFor(OPERATION_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toBe("operation status does not allow this");
  });

  it("RPC no_data_found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx(ENABLED_PROFILE, {
        data: null,
        error: { code: "P0002", message: "operation not found" },
      }),
    );

    const response = await POST(
      request({ reason: VALID_REASON }),
      paramsFor(OPERATION_ID),
    );

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

    const response = await POST(
      request({ reason: VALID_REASON }),
      paramsFor(OPERATION_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(409);
    expect(body.error).toBe("Operation changed concurrently, retry");
  });

  it("success -> 200 { ok: true, newStatus } and trims the reason before calling RPC", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx(ENABLED_PROFILE, {
      data: { new_status: "completed", completed_at: "2026-10-02T10:00:00Z" },
      error: null,
    });
    requireRole.mockResolvedValueOnce(callCtx);

    const response = await POST(
      request({ reason: `  ${VALID_REASON}  ` }),
      paramsFor(OPERATION_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_cerrar_operacion_manual", {
      p_operation_id: OPERATION_ID,
      p_motivo: VALID_REASON,
    });
    expect(body).toEqual({ ok: true, newStatus: "completed", completedAt: "2026-10-02T10:00:00Z" });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });
});
