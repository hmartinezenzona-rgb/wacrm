import { beforeEach, describe, expect, it, vi } from "vitest";

const getCurrentAccount = vi.fn();
const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ getCurrentAccount, requireRole, toErrorResponse }));

const upsert = vi.fn();
const update = vi.fn();
const rpc = vi.fn();
const admin = {
  rpc,
  from: vi.fn(() => ({ upsert, update })),
};
vi.mock("@/lib/flows/admin-client", () => ({ supabaseAdmin: () => admin }));

const RPC_RESULT = {
  motivo: "porque salimos",
  hasta: "2026-10-21T19:00:00Z",
  hasta_texto: "a las 3:00 pm",
  por: "Ana",
};

function sessionClient(fullName: string | null) {
  const builder = {
    select: vi.fn(() => builder),
    eq: vi.fn(() => builder),
    maybeSingle: vi.fn(() => Promise.resolve({ data: fullName === null ? null : { full_name: fullName }, error: null })),
  };
  return { from: vi.fn(() => builder) };
}

function asRole(role: string, fullName: string | null = "Ana") {
  const ctx = {
    supabase: sessionClient(fullName),
    userId: "user-a",
    accountId: "acc-a",
    role,
    account: { id: "acc-a", name: "A" },
  };
  getCurrentAccount.mockResolvedValue(ctx);
  requireRole.mockImplementation(async () => {
    if (role !== "admin" && role !== "owner") {
      throw Object.assign(new Error("This action requires the 'admin' role or higher"), { status: 403 });
    }
    return ctx;
  });
  return ctx;
}

function put(body: unknown) {
  return new Request("http://local/api/ausencia", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

const inHours = (h: number) => new Date(Date.now() + h * 3600_000).toISOString();

beforeEach(() => {
  vi.clearAllMocks();
  upsert.mockResolvedValue({ error: null });
  update.mockReturnValue({ eq: vi.fn(() => Promise.resolve({ error: null })) });
  rpc.mockResolvedValue({ data: RPC_RESULT, error: null });
  admin.from.mockImplementation(() => ({ upsert, update }));
  asRole("admin");
});

describe("GET /api/ausencia", () => {
  it("unauthenticated -> 401", async () => {
    const { GET } = await import("./route");
    getCurrentAccount.mockRejectedValueOnce(Object.assign(new Error("Unauthorized"), { status: 401 }));
    expect((await GET()).status).toBe(401);
  });

  it("any member (agent) gets the rpc result", async () => {
    const { GET } = await import("./route");
    asRole("agent");
    const response = await GET();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ausencia: RPC_RESULT });
    expect(rpc).toHaveBeenCalledWith("cerebro_ausencia_actual");
  });

  it("returns null when there is no active absence", async () => {
    const { GET } = await import("./route");
    rpc.mockResolvedValueOnce({ data: null, error: null });
    expect(await (await GET()).json()).toEqual({ ausencia: null });
  });
});

describe("PUT /api/ausencia", () => {
  it("unauthenticated -> 401", async () => {
    const { PUT } = await import("./route");
    requireRole.mockRejectedValueOnce(Object.assign(new Error("Unauthorized"), { status: 401 }));
    expect((await PUT(put({ hasta: inHours(2), motivo: "x" }))).status).toBe(401);
  });

  it.each(["agent", "viewer"])("%s -> 403 and nothing is written", async (role) => {
    const { PUT } = await import("./route");
    asRole(role);
    const response = await PUT(put({ hasta: inHours(2), motivo: "x" }));
    expect(response.status).toBe(403);
    expect(upsert).not.toHaveBeenCalled();
  });

  it.each([
    ["past", () => inHours(-2)],
    ["more than 7 days ahead", () => inHours(24 * 8)],
    ["garbage", () => "no es fecha"],
  ])("admin with hasta %s -> 400", async (_name, make) => {
    const { PUT } = await import("./route");
    const response = await PUT(put({ hasta: make(), motivo: "porque salimos" }));
    expect(response.status).toBe(400);
    expect(await response.json()).toHaveProperty("error");
    expect(upsert).not.toHaveBeenCalled();
  });

  it.each([["empty", ""], ["too long", "a".repeat(121)]])("admin with %s motivo -> 400", async (_n, motivo) => {
    const { PUT } = await import("./route");
    const response = await PUT(put({ hasta: inHours(2), motivo }));
    expect(response.status).toBe(400);
    expect(upsert).not.toHaveBeenCalled();
  });

  it("invalid JSON body -> 400", async () => {
    const { PUT } = await import("./route");
    const request = new Request("http://local/api/ausencia", { method: "PUT", body: "{nope" });
    expect((await PUT(request)).status).toBe(400);
  });

  it("admin ok writes the ausencia JSON (por, desde, normalized hasta) and returns the rpc result", async () => {
    const { PUT } = await import("./route");
    const hasta = inHours(3);
    const before = Date.now();
    const response = await PUT(put({ hasta, motivo: "  porque salimos  " }));
    const after = Date.now();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ausencia: RPC_RESULT });
    expect(admin.from).toHaveBeenCalledWith("cerebro_config");
    expect(upsert).toHaveBeenCalledTimes(1);
    const [payload, options] = upsert.mock.calls[0];
    expect(options).toEqual({ onConflict: "clave" });
    expect(payload.clave).toBe("ausencia");
    expect(typeof payload.actualizado).toBe("string");
    const valor = JSON.parse(payload.valor);
    expect(valor.hasta).toBe(new Date(hasta).toISOString());
    expect(valor.motivo).toBe("porque salimos");
    expect(valor.por).toBe("Ana");
    expect(Date.parse(valor.desde)).toBeGreaterThanOrEqual(before);
    expect(Date.parse(valor.desde)).toBeLessThanOrEqual(after);
    expect(Object.keys(valor).sort()).toEqual(["desde", "hasta", "motivo", "por"]);
  });

  it("falls back to 'un admin' when the profile has no name", async () => {
    const { PUT } = await import("./route");
    asRole("admin", null);
    await PUT(put({ hasta: inHours(3), motivo: "x" }));
    expect(JSON.parse(upsert.mock.calls[0][0].valor).por).toBe("un admin");
  });

  it("write error -> 500 without leaking details", async () => {
    const { PUT } = await import("./route");
    upsert.mockResolvedValueOnce({ error: { message: "secret db detail" } });
    const response = await PUT(put({ hasta: inHours(3), motivo: "x" }));
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain("secret");
  });
});

describe("DELETE /api/ausencia", () => {
  it("agent -> 403", async () => {
    const { DELETE } = await import("./route");
    asRole("agent");
    expect((await DELETE()).status).toBe(403);
    expect(upsert).not.toHaveBeenCalled();
  });

  it("admin writes an empty valor and returns { ausencia: null }", async () => {
    const { DELETE } = await import("./route");
    const response = await DELETE();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ausencia: null });
    expect(upsert).toHaveBeenCalledTimes(1);
    const [payload, options] = upsert.mock.calls[0];
    expect(payload.clave).toBe("ausencia");
    expect(payload.valor).toBe("");
    expect(options).toEqual({ onConflict: "clave" });
  });
});
