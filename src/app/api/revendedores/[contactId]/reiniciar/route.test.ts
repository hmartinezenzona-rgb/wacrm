// Route-level tests for POST /api/revendedores/{contactId}/reiniciar.
// Covers admin-only gating, UUID/body validation, RPC arguments, the
// 40001 -> 409 stale-total mapping carrying the current total, and the
// P0002/22023/42501 mappings.

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
  return new Request(`http://local/api/revendedores/${CONTACT_ID}/reiniciar`, {
    method: "POST",
    body: raw ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

const RESET = {
  reset_id: "reset-1",
  contact_id: CONTACT_ID,
  reset_at: "2026-11-24T10:00:00Z",
  closed: { operations_gyd: "2100", adjustments_gyd: "0", total_gyd: "2100" },
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/revendedores/[contactId]/reiniciar", () => {
  it("caller below admin -> 403", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });

    const response = await POST(jsonRequest({}), params(CONTACT_ID));

    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("non-UUID contactId -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);

    expect((await POST(jsonRequest({}), params("nope"))).status).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("invalid JSON body -> 400", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: null }));

    expect((await POST(jsonRequest(undefined, "{bad"), params(CONTACT_ID))).status).toBe(400);
  });

  it("invalid payload -> 400, RPC never called", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(c);

    expect(
      (await POST(jsonRequest({ expectedTotalGyd: "2100" }), params(CONTACT_ID))).status,
    ).toBe(400);
    expect(c.supabase.rpc).not.toHaveBeenCalled();
  });

  it("resets the contact with trimmed reason and expected total", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: RESET, error: null });
    requireRole.mockResolvedValueOnce(c);

    const response = await POST(
      jsonRequest({ reason: "  cierre  ", expectedTotalGyd: 2100 }),
      params(CONTACT_ID),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_revendedor_reiniciar", {
      p_contact_id: CONTACT_ID,
      p_motivo: "cierre",
      p_total_esperado_gyd: 2100,
    });
    expect(body.reset).toEqual({
      resetId: "reset-1",
      contactId: CONTACT_ID,
      resetAt: "2026-11-24T10:00:00Z",
      closed: { operationsGyd: 2100, adjustmentsGyd: 0, totalGyd: 2100 },
    });
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("omitted reason and expected total reach the RPC as null", async () => {
    const { POST } = await import("./route");
    const c = ctx({ data: RESET, error: null });
    requireRole.mockResolvedValueOnce(c);

    await POST(jsonRequest({}), params(CONTACT_ID));

    expect(c.supabase.rpc).toHaveBeenCalledWith("crm_revendedor_reiniciar", {
      p_contact_id: CONTACT_ID,
      p_motivo: null,
      p_total_esperado_gyd: null,
    });
  });

  it("RPC stale expected total (40001) -> 409 with the current total from the hint", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "40001", message: "expected differs", hint: "2500" } }),
    );

    const response = await POST(jsonRequest({ expectedTotalGyd: 2100 }), params(CONTACT_ID));
    const body = await response.json();

    expect(response.status).toBe(409);
    expect(body.currentTotalGyd).toBe(2500);
  });

  it("RPC not a reseller / invalid amount (22023) -> 400 with its message", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "22023", message: "the contact is not a reseller" } }),
    );

    const response = await POST(jsonRequest({}), params(CONTACT_ID));
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error).toMatch(/not a reseller/);
  });

  it("RPC contact not found (P0002) -> 404", async () => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(
      ctx({ data: null, error: { code: "P0002", message: "contact not found" } }),
    );

    expect((await POST(jsonRequest({}), params(CONTACT_ID))).status).toBe(404);
  });
});
