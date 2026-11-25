// Route-level tests for GET /api/revendedores/{contactId}.
// Covers member read gating, UUID validation, RPC name/argument, the
// P0002 -> 404 mapping, and the mapped detail payload.

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

const CONTACT_ID = "11111111-1111-1111-1111-111111111111";

function params(contactId: string) {
  return { params: Promise.resolve({ contactId }) };
}

const DETAIL = {
  contact_id: CONTACT_ID,
  name: "Ana",
  phone: "+584120000000",
  is_reseller: true,
  pending_claims: 2,
  current: {
    period_start: "2026-11-01T10:00:00Z",
    deposits_gyd: "5000",
    deposits_count: 2,
    operations_gyd: "9000",
    operations_count: 2,
    operations_missing_amount: 0,
    adjustments_gyd: "-1000",
    adjustments_count: 1,
    counted_gyd: "14000",
    total_gyd: "13000",
    adjustments: [
      {
        id: "adj-1",
        amount_gyd: "-1000",
        reason: null,
        actor_name: "Admin",
        created_at: "2026-11-02T10:00:00Z",
      },
    ],
  },
  periods: [],
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("GET /api/revendedores/[contactId]", () => {
  it("unauthenticated request -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });

    expect((await GET(new Request("http://local"), params(CONTACT_ID))).status).toBe(401);
    expect(requireRole).toHaveBeenCalledWith("viewer");
  });

  it("non-UUID contactId -> 400, RPC never called", async () => {
    const { GET } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);

    expect((await GET(new Request("http://local"), params("not-a-uuid"))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("reads the detail for the contact and returns the mapped reseller", async () => {
    const { GET } = await import("./route");
    const c = ctx({ data: DETAIL, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await GET(new Request("http://local"), params(CONTACT_ID));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_revendedor_detalle", {
      p_contact_id: CONTACT_ID,
    });
    expect(body.reseller).toMatchObject({
      contactId: CONTACT_ID,
      isReseller: true,
      pendingClaims: 2,
      current: {
        depositsGyd: 5000,
        depositsCount: 2,
        countedGyd: 14000,
        totalGyd: 13000,
        adjustmentsGyd: -1000,
      },
    });
    expect(body.reseller.current.adjustments[0]).toMatchObject({ id: "adj-1", reason: null });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("RPC contact not found (P0002) -> 404", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "P0002", message: "contact not found" } }),
    );

    expect((await GET(new Request("http://local"), params(CONTACT_ID))).status).toBe(404);
  });

  it("RPC membership failure (42501) -> 403", async () => {
    const { GET } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "42501", message: "not a member of this account" } }),
    );

    expect((await GET(new Request("http://local"), params(CONTACT_ID))).status).toBe(403);
  });
});
