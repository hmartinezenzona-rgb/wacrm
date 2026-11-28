// Route-level tests for POST /api/revendedores/{contactId}/ajustes.
// Covers admin-only gating, UUID/body validation (signed non-zero amount,
// optional reason), RPC arguments, and the 22023/42501/P0002 mappings.

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

const CONTACT_ID = "11111111-1111-1111-1111-111111111111";

function params(contactId: string) {
  return { params: Promise.resolve({ contactId }) };
}

function jsonRequest(body?: unknown, raw?: string) {
  return new Request(`http://local/api/revendedores/${CONTACT_ID}/ajustes`, {
    method: "POST",
    body: raw ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const ADJUSTMENT = {
  adjustment_id: "adj-1",
  contact_id: CONTACT_ID,
  amount_gyd: "-1000",
  created_at: "2026-11-24T10:00:00Z",
  total_before_gyd: "9000",
  total_after_gyd: "8000",
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/revendedores/[contactId]/ajustes", () => {
  it("caller below admin -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });

    const response = await POST(jsonRequest({ amountGyd: 100 }), params(CONTACT_ID));

    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("non-UUID contactId -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);

    expect((await POST(jsonRequest({ amountGyd: 100 }), params("nope"))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    expect((await POST(jsonRequest(undefined, "{bad"), params(CONTACT_ID))).status).toBe(400);
  });

  it.each([
    ["a missing amount", {}],
    ["a zero amount", { amountGyd: 0 }],
    ["a string amount", { amountGyd: "100" }],
    ["a reason longer than 500 characters", { amountGyd: 1, reason: "x".repeat(501) }],
    ["an unknown field", { amountGyd: 1, total: 2 }],
  ])("%s -> 400, RPC never called", async (_label, body) => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);

    expect((await POST(jsonRequest(body), params(CONTACT_ID))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("adds the adjustment with the contact, amount and trimmed reason", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: ADJUSTMENT, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await POST(
      jsonRequest({ amountGyd: -1000, reason: "  corrección  " }),
      params(CONTACT_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_revendedor_ajustar", {
      p_contact_id: CONTACT_ID,
      p_monto_gyd: -1000,
      p_motivo: "corrección",
    });
    expect(body.adjustment).toEqual({
      adjustmentId: "adj-1",
      contactId: CONTACT_ID,
      amountGyd: -1000,
      createdAt: "2026-11-24T10:00:00Z",
      totalBeforeGyd: 9000,
      totalAfterGyd: 8000,
    });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("omitted reason reaches the RPC as null", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: ADJUSTMENT, error: null });
    requireRole.mockResolvedValueOnce(c);

    await POST(jsonRequest({ amountGyd: 500 }), params(CONTACT_ID));

    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_revendedor_ajustar", {
      p_contact_id: CONTACT_ID,
      p_monto_gyd: 500,
      p_motivo: null,
    });
  });

  it("RPC validation (22023) -> 400 with its message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "22023", message: "the contact is not a reseller" } }),
    );

    const response = await POST(jsonRequest({ amountGyd: 500 }), params(CONTACT_ID));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toMatch(/not a reseller/);
  });

  it("RPC insufficient privilege (42501) -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "42501", message: "only an owner or admin" } }),
    );

    expect((await POST(jsonRequest({ amountGyd: 500 }), params(CONTACT_ID))).status).toBe(403);
  });

  it("RPC contact not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "P0002", message: "contact not found" } }),
    );

    expect((await POST(jsonRequest({ amountGyd: 500 }), params(CONTACT_ID))).status).toBe(404);
  });
});
