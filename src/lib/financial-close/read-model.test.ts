import { describe, expect, it } from "vitest";
import { mapFinancialClose, type FinancialCloseRpc } from "./read-model";

const RAW: FinancialCloseRpc = {
  desde: "2026-08-03",
  hasta: "2026-08-04",
  zona: "America/Guyana",
  totales: { operaciones: 2, facturado_gyd: "3000.50", invertido_gyd: 2200, retorno_gyd: "800.50" },
  por_servicio: [
    { service: "ZELLE", operaciones: 1, facturado_gyd: 2000, invertido_gyd: 1500, retorno_gyd: 500 },
    { service: "CUP", operaciones: 1, facturado_gyd: "1000.50", invertido_gyd: 700, retorno_gyd: "300.50" },
  ],
  por_dia: [
    { dia: "2026-08-03", operaciones: 0, facturado_gyd: 0, invertido_gyd: 0, retorno_gyd: 0 },
    { dia: "2026-08-04", operaciones: 2, facturado_gyd: "3000.50", invertido_gyd: 2200, retorno_gyd: "800.50" },
  ],
  detalle: [
    {
      id: "e1",
      operation_id: "op1",
      dia: "2026-08-04",
      completed_at: "2026-08-04T15:00:00+00:00",
      customer_name: "Ana",
      service: "CUP",
      amount: "3000",
      amount_currency: "CUP",
      cup_rate: "975",
      cup_global_rate: "3",
      usdt_buy_gyd: null,
      usdt_sell_gyd: null,
      rate_version_id: "rv1",
      facturado_gyd: "1000.50",
      invertido_gyd: 700,
      retorno_gyd: "300.50",
      delivery_mode: "proof_sent",
      actor_user_id: "u1",
      actor_name: "Humberto",
      source: "completed_operation",
    },
    {
      id: "m1",
      operation_id: null,
      source: "manual",
      dia: "2026-08-04",
      completed_at: "2026-08-04T16:00:00+00:00",
      customer_name: "Gerardo",
      service: "ZELLE",
      amount: "100",
      amount_currency: "USD",
      cup_rate: null,
      cup_global_rate: null,
      usdt_buy_gyd: null,
      usdt_sell_gyd: null,
      rate_version_id: null,
      facturado_gyd: "26000",
      invertido_gyd: "24000",
      retorno_gyd: "2000",
      delivery_mode: null,
      actor_user_id: "u2",
      actor_name: "Osmany",
    },
  ],
  excluidas: [
    {
      id: "e3",
      operation_id: "op3",
      dia: "2026-08-04",
      completed_at: null,
      customer_name: null,
      service: "CUP",
      amount: 1000,
      amount_currency: "CUP",
      cup_rate: null,
      cup_global_rate: null,
      usdt_buy_gyd: null,
      usdt_sell_gyd: null,
      rate_version_id: null,
      facturado_gyd: null,
      invertido_gyd: null,
      retorno_gyd: null,
      delivery_mode: null,
      actor_user_id: null,
      actor_name: null,
      status: "verified_pending",
      void_reason: null,
      voided_at: null,
      missing_inputs: ["cup_rate"],
    },
  ],
};

describe("mapFinancialClose", () => {
  it("maps the RPC payload to numbers and camelCase, keeping every row", () => {
    const close = mapFinancialClose(RAW);
    expect(close.range).toEqual({ desde: "2026-08-03", hasta: "2026-08-04" });
    expect(close.totals).toEqual({ operations: 2, facturadoGyd: 3000.5, invertidoGyd: 2200, retornoGyd: 800.5 });
    expect(close.byService.map((s) => [s.service, s.facturadoGyd])).toEqual([
      ["ZELLE", 2000],
      ["CUP", 1000.5],
    ]);
    expect(close.byDay).toHaveLength(2);
    expect(close.byDay[1]).toEqual({ day: "2026-08-04", operations: 2, facturadoGyd: 3000.5, invertidoGyd: 2200, retornoGyd: 800.5 });
    expect(close.detail[0]).toMatchObject({
      id: "e1",
      operationId: "op1",
      day: "2026-08-04",
      customerName: "Ana",
      amount: 3000,
      cupRate: 975,
      usdtBuyGyd: null,
      facturadoGyd: 1000.5,
      deliveryMode: "proof_sent",
      actorName: "Humberto",
    });
    expect(close.excluded[0]).toMatchObject({
      id: "e3",
      status: "verified_pending",
      facturadoGyd: null,
      missingInputs: ["cup_rate"],
      voidReason: null,
    });
  });

  it("keeps the origin of every row: a manual Calculator line has no operation and says so; older payloads read as chat", () => {
    const close = mapFinancialClose(RAW);
    expect(close.detail.map((e) => [e.id, e.source, e.operationId])).toEqual([
      ["e1", "completed_operation", "op1"],
      ["m1", "manual", null],
    ]);
    const { source: _source, ...withoutSource } = RAW.detalle[0]!;
    void _source;
    expect(mapFinancialClose({ ...RAW, detalle: [withoutSource], excluidas: [] }).detail[0]!.source).toBe("completed_operation");
  });

  it("tolerates empty lists and null totals from an empty period", () => {
    const close = mapFinancialClose({
      ...RAW,
      totales: { operaciones: 0, facturado_gyd: 0, invertido_gyd: 0, retorno_gyd: 0 },
      por_servicio: [],
      detalle: [],
      excluidas: [],
    });
    expect(close.totals.facturadoGyd).toBe(0);
    expect(close.byService).toEqual([]);
    expect(close.detail).toEqual([]);
    expect(close.excluded).toEqual([]);
  });
});
