import { describe, expect, it, vi } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import { loadFinancialClose } from "./load";

function fakeDb(result: { data: unknown; error: unknown }) {
  const rpc = vi.fn().mockResolvedValue(result);
  return { db: { rpc } as unknown as SupabaseClient, rpc };
}

const EMPTY = {
  desde: "2026-09-01",
  hasta: "2026-09-01",
  zona: "America/Guyana",
  totales: { operaciones: 0, facturado_gyd: 0, invertido_gyd: 0, retorno_gyd: 0 },
  por_servicio: [],
  por_dia: [{ dia: "2026-09-01", operaciones: 0, facturado_gyd: 0, invertido_gyd: 0, retorno_gyd: 0 }],
  detalle: [],
  excluidas: [],
};

describe("loadFinancialClose", () => {
  it("calls crm_cierre_financiero with the range and returns the mapped close", async () => {
    const { db, rpc } = fakeDb({ data: EMPTY, error: null });
    const result = await loadFinancialClose(db, { desde: "2026-09-01", hasta: "2026-09-01" });
    expect(rpc).toHaveBeenCalledWith("crm_cierre_financiero", { p_desde: "2026-09-01", p_hasta: "2026-09-01" });
    expect(result).toMatchObject({ ok: true, data: { totals: { operations: 0 } } });
  });

  it("rejects an invalid range before calling the database", async () => {
    const { db, rpc } = fakeDb({ data: EMPTY, error: null });
    const result = await loadFinancialClose(db, { desde: "2026-09-02", hasta: "2026-09-01" });
    expect(rpc).not.toHaveBeenCalled();
    expect(result).toEqual({ ok: false, error: "reversed" });
  });

  it("reports a database error without throwing", async () => {
    const { db } = fakeDb({ data: null, error: { message: "boom", code: "XX000" } });
    const result = await loadFinancialClose(db, { desde: "2026-09-01", hasta: "2026-09-01" });
    expect(result).toEqual({ ok: false, error: "load_failed" });
  });

  it("reports a missing payload as a failure, not an empty close", async () => {
    const { db } = fakeDb({ data: null, error: null });
    const result = await loadFinancialClose(db, { desde: "2026-09-01", hasta: "2026-09-01" });
    expect(result).toEqual({ ok: false, error: "load_failed" });
  });
});
