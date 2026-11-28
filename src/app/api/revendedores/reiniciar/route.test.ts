// Route-level tests for POST /api/revendedores/reiniciar (reset all).
// Covers admin-only gating, body validation, RPC name/arguments, the
// 40001 -> 409 stale-grand-total mapping with the current total, and the
// batch response shape.

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
  return {
    supabase: { rpc },
    userId: "user-a",
    accountId: "account-a",
    role: "admin" as const,
    account: { id: "account-a", name: "A" },
  };
}

function jsonRequest(body?: unknown, raw?: string) {
  return new Request("http://local/api/revendedores/reiniciar", {
    method: "POST",
    body: raw ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const BATCH = {
  batch_id: "batch-1",
  reset_at: "2026-11-24T10:00:00Z",
  count: 1,
  grand_total_gyd: "2100",
  resets: [{ reset_id: "reset-1", contact_id: "contact-1", total_gyd: "2100" }],
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/revendedores/reiniciar", () => {
  it("caller below admin -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });

    const response = await POST(jsonRequest({}));

    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    expect((await POST(jsonRequest(undefined, "{not-json"))).status).toBe(400);
  });

  it("invalid payload -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);

    expect((await POST(jsonRequest({ expectedTotal: 10 }))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("resets all with the caller's account, trimmed reason and expected grand total", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: BATCH, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await POST(
      jsonRequest({ reason: "  cierre global  ", expectedGrandTotalGyd: 2100 }),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_revendedores_reiniciar_todos", {
      p_account_id: "account-a",
      p_motivo: "cierre global",
      p_total_esperado_gyd: 2100,
    });
    expect(body.batch).toEqual({
      batchId: "batch-1",
      resetAt: "2026-11-24T10:00:00Z",
      count: 1,
      grandTotalGyd: 2100,
      resets: [{ resetId: "reset-1", contactId: "contact-1", totalGyd: 2100 }],
    });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("omitted reason and expected total reach the RPC as null", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: BATCH, error: null });
    requireRole.mockResolvedValueOnce(c);

    await POST(jsonRequest({}));

    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_revendedores_reiniciar_todos", {
      p_account_id: "account-a",
      p_motivo: null,
      p_total_esperado_gyd: null,
    });
  });

  it("RPC stale expected grand total (40001) -> 409 with the current total from the hint", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({
        data: null,
        error: { code: "40001", message: "expected differs", hint: "2500" },
      }),
    );

    const response = await POST(jsonRequest({ expectedGrandTotalGyd: 2100 }));
    const body = await response.json();

    expect(response.status).toBe(409);
    expect(body.currentGrandTotalGyd).toBe(2500);
    expect(typeof body.error).toBe("string");
  });

  it("40001 without a numeric hint still maps to 409 with a null current total", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "40001", message: "expected differs" } }),
    );

    const response = await POST(jsonRequest({}));
    const body = await response.json();

    expect(response.status).toBe(409);
    expect(body.currentGrandTotalGyd).toBeNull();
  });

  it("RPC reason/amount validation (22023) -> 400 with its message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "22023", message: "the reason cannot exceed 500 characters" } }),
    );

    const response = await POST(jsonRequest({ reason: "x" }));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toMatch(/500 characters/);
  });

  it("RPC insufficient privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "42501", message: "only an owner or admin" } }),
    );

    expect((await POST(jsonRequest({}))).status).toBe(403);
  });
});
