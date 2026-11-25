// Route-level tests for GET /api/revendedores (Finanzas reseller list).
// Covers member read gating, the RPC name/argument, the mapped read model
// and the 42501 -> 403 mapping from the RPC's own membership check.

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
    role: "viewer" as const,
    account: { id: "account-a", name: "A" },
  };
}

const SUMMARY = {
  grand: { operations_gyd: "12000", adjustments_gyd: "-2000", total_gyd: "10000", resellers: 2 },
  resellers: [
    {
      contact_id: "contact-1",
      name: "Ana",
      phone: "+584120000000",
      period_start: "2026-11-01T10:00:00Z",
      operations_gyd: "9000",
      operations_count: 2,
      operations_missing_amount: 0,
      adjustments_gyd: "-1000",
      adjustments_count: 1,
      total_gyd: "8000",
    },
  ],
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/revendedores", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    const response = await GET();

    expect(response.status).toBe(401);
    expect(requireRole).toHaveBeenCalledWith("viewer");
  });

  it("reads the summary with the caller's account and returns the mapped payload", async () => {
    const { GET } = await import("./route");
    const c = ctx({ data: SUMMARY, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await GET();
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_revendedores_resumen", {
      p_account_id: "account-a",
    });
    expect(body.grand).toEqual({
      operationsGyd: 12000,
      adjustmentsGyd: -2000,
      totalGyd: 10000,
      resellers: 2,
    });
    expect(body.resellers[0]).toMatchObject({ contactId: "contact-1", totalGyd: 8000 });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("returns zeros and an empty list when the RPC returns an empty payload", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    const body = await (await GET()).json();

    expect(body).toEqual({
      grand: { operationsGyd: 0, adjustmentsGyd: 0, totalGyd: 0, resellers: 0 },
      resellers: [],
    });
  });

  it("RPC insufficient_privilege (42501) -> 403", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "42501", message: "not a member of this account" } }),
    );

    expect((await GET()).status).toBe(403);
  });

  it("an unexpected RPC error -> 500", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "XX000", message: "boom" } }),
    );
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    expect((await GET()).status).toBe(500);
    errorSpy.mockRestore();
  });
});
