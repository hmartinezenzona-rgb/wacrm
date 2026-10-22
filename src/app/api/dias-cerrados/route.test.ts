import { beforeEach, describe, expect, it, vi } from "vitest";

const requireRole = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  const message = status >= 500 ? "Internal server error" : (error as Error).message;
  return new Response(JSON.stringify({ error: message }), { status });
};

vi.mock("@/lib/auth/account", () => ({ requireRole, toErrorResponse }));

const upsert = vi.fn();
const maybeSingle = vi.fn();
const selectBuilder = { eq: vi.fn(() => ({ maybeSingle })) };
const admin = {
  from: vi.fn(() => ({ upsert, select: vi.fn(() => selectBuilder) })),
};
vi.mock("@/lib/flows/admin-client", () => ({ supabaseAdmin: () => admin }));

function asRole(role: string) {
  requireRole.mockImplementation(async () => {
    if (role !== "admin" && role !== "owner") {
      throw Object.assign(new Error("This action requires the 'admin' role or higher"), { status: 403 });
    }
    return { userId: "u", accountId: "a", role };
  });
}

function put(body: unknown) {
  return new Request("http://local/api/dias-cerrados", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  upsert.mockResolvedValue({ error: null });
  maybeSingle.mockResolvedValue({ data: { valor: "[]" }, error: null });
  selectBuilder.eq.mockImplementation(() => ({ maybeSingle }));
  admin.from.mockImplementation(() => ({ upsert, select: vi.fn(() => selectBuilder) }));
  asRole("admin");
});

describe("GET /api/dias-cerrados", () => {
  it("unauthenticated -> 401", async () => {
    const { GET } = await import("./route");
    requireRole.mockRejectedValueOnce(Object.assign(new Error("Unauthorized"), { status: 401 }));
    expect((await GET()).status).toBe(401);
  });

  it("agent -> 403", async () => {
    const { GET } = await import("./route");
    asRole("agent");
    expect((await GET()).status).toBe(403);
  });

  it("returns the stored days sorted ascending", async () => {
    const { GET } = await import("./route");
    maybeSingle.mockResolvedValueOnce({
      data: {
        valor: JSON.stringify([
          { fecha: "2026-12-25", motivo: "porque es Navidad" },
          { fecha: "2026-10-05", motivo: "porque aniversario" },
        ]),
      },
      error: null,
    });
    const response = await GET();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      dias: [
        { fecha: "2026-10-05", motivo: "porque aniversario" },
        { fecha: "2026-12-25", motivo: "porque es Navidad" },
      ],
    });
    expect(selectBuilder.eq).toHaveBeenCalledWith("clave", "dias_cerrados");
  });

  it("broken stored JSON -> 200 with []", async () => {
    const { GET } = await import("./route");
    maybeSingle.mockResolvedValueOnce({ data: { valor: "{broken" }, error: null });
    const response = await GET();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ dias: [] });
  });

  it("missing row -> 200 with []", async () => {
    const { GET } = await import("./route");
    maybeSingle.mockResolvedValueOnce({ data: null, error: null });
    expect(await (await GET()).json()).toEqual({ dias: [] });
  });
});

describe("PUT /api/dias-cerrados", () => {
  it("unauthenticated -> 401", async () => {
    const { PUT } = await import("./route");
    requireRole.mockRejectedValueOnce(Object.assign(new Error("Unauthorized"), { status: 401 }));
    expect((await PUT(put({ dias: [] }))).status).toBe(401);
  });

  it("agent -> 403 and nothing is written", async () => {
    const { PUT } = await import("./route");
    asRole("agent");
    expect((await PUT(put({ dias: [] }))).status).toBe(403);
    expect(upsert).not.toHaveBeenCalled();
  });

  it("invalid date 2026-02-30 -> 400", async () => {
    const { PUT } = await import("./route");
    const response = await PUT(put({ dias: [{ fecha: "2026-02-30", motivo: "porque x" }] }));
    expect(response.status).toBe(400);
    expect(upsert).not.toHaveBeenCalled();
  });

  it("duplicate dates -> 400", async () => {
    const { PUT } = await import("./route");
    const response = await PUT(put({ dias: [
      { fecha: "2026-10-05", motivo: "a" },
      { fecha: "2026-10-05", motivo: "b" },
    ] }));
    expect(response.status).toBe(400);
    expect(upsert).not.toHaveBeenCalled();
  });

  it("more than 60 entries -> 400", async () => {
    const { PUT } = await import("./route");
    const dias = Array.from({ length: 61 }, (_, i) => ({
      fecha: new Date(Date.UTC(2027, 0, 1 + i)).toISOString().slice(0, 10),
      motivo: "x",
    }));
    expect((await PUT(put({ dias }))).status).toBe(400);
    expect(upsert).not.toHaveBeenCalled();
  });

  it("invalid JSON body -> 400", async () => {
    const { PUT } = await import("./route");
    const request = new Request("http://local/api/dias-cerrados", { method: "PUT", body: "{nope" });
    expect((await PUT(request)).status).toBe(400);
  });

  it("sorts ascending, writes JSON to dias_cerrados and returns the days", async () => {
    const { PUT } = await import("./route");
    const response = await PUT(put({ dias: [
      { fecha: "2026-12-25", motivo: " porque es Navidad " },
      { fecha: "2026-10-05", motivo: "porque aniversario" },
    ] }));
    const sorted = [
      { fecha: "2026-10-05", motivo: "porque aniversario" },
      { fecha: "2026-12-25", motivo: "porque es Navidad" },
    ];
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ dias: sorted });
    const [payload, options] = upsert.mock.calls[0];
    expect(payload.clave).toBe("dias_cerrados");
    expect(payload.valor).toBe(JSON.stringify(sorted));
    expect(options).toEqual({ onConflict: "clave" });
  });

  it("an empty list writes '[]'", async () => {
    const { PUT } = await import("./route");
    await PUT(put({ dias: [] }));
    expect(upsert.mock.calls[0][0].valor).toBe("[]");
  });
});
