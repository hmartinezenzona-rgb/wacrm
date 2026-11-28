// Route-level tests for POST /api/calculator/entries/{entryId}/delete: admin-only, UUID check, RPC error mapping,
// and the response shape. The deletion itself (durable void, audit, feed never revives it) is guarded by
// supabase/staging/assertions/calculator-entry-delete.sql.

import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const ENTRY_ID = "11111111-1111-1111-1111-111111111111";

function ctx(rpcResult: { data: unknown; error: unknown }) {
  const rpc = vi.fn(() => Promise.resolve(rpcResult));
  return { supabase: { rpc }, userId: "user-a", accountId: "account-a", role: "admin" as const };
}

const request = () => new Request(`http://local/api/calculator/entries/${ENTRY_ID}/delete`, { method: "POST" });
const paramsFor = (entryId: string) => ({ params: Promise.resolve({ entryId }) });

beforeEach(() => {
  vi.clearAllMocks();
});

describe("POST /api/calculator/entries/[entryId]/delete", () => {
  it("requires admin and rejects a lower role", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Forbidden", status: 403 });
    const response = await POST(request(), paramsFor(ENTRY_ID));
    expect(response.status).toBe(403);
    expect(requireRole).toHaveBeenCalledWith("admin");
  });

  it("unauthenticated -> 401", async () => {
    const { POST } = await import("./route");
    requireRole.mockRejectedValueOnce({ message: "Unauthorized", status: 401 });
    expect((await POST(request(), paramsFor(ENTRY_ID))).status).toBe(401);
  });

  it("malformed entryId -> 400 and the RPC is never called", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: null, error: null });
    requireRole.mockResolvedValueOnce(callCtx);
    const response = await POST(request(), paramsFor("not-a-uuid"));
    expect(response.status).toBe(400);
    expect(callCtx.supabase.rpc).not.toHaveBeenCalled();
  });

  it("calls crm_eliminar_entrada_calculadora on the session client and answers with the deleted id", async () => {
    const { POST } = await import("./route");
    const callCtx = ctx({ data: { id: ENTRY_ID, status: "void" }, error: null });
    requireRole.mockResolvedValueOnce(callCtx);
    const response = await POST(request(), paramsFor(ENTRY_ID));
    expect(response.status).toBe(200);
    expect(callCtx.supabase.rpc).toHaveBeenCalledWith("crm_eliminar_entrada_calculadora", { p_entry_id: ENTRY_ID });
    expect(await response.json()).toEqual({ deleted: true, entryId: ENTRY_ID });
  });

  it.each([
    ["42501", 403],
    ["22023", 400],
    ["P0002", 404],
  ])("RPC error %s -> %i", async (code, status) => {
    const { POST } = await import("./route");
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code, message: "boom" } }));
    expect((await POST(request(), paramsFor(ENTRY_ID))).status).toBe(status);
  });

  it("an unexpected RPC error -> 500", async () => {
    const { POST } = await import("./route");
    vi.spyOn(console, "error").mockImplementation(() => {});
    requireRole.mockResolvedValueOnce(ctx({ data: null, error: { code: "XX000", message: "db down" } }));
    expect((await POST(request(), paramsFor(ENTRY_ID))).status).toBe(500);
  });
});
