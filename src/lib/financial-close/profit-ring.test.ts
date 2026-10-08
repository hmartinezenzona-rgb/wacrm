import { describe, expect, it } from "vitest";
import { buildProfitRing } from "./profit-ring";

const svc = (service: string, retornoGyd: number) => ({
  service,
  operations: 1,
  facturadoGyd: 0,
  invertidoGyd: 0,
  retornoGyd,
});

describe("buildProfitRing", () => {
  it("has no ring and no rows without services (no NaN)", () => {
    const ring = buildProfitRing([]);
    expect(ring).toEqual({ rows: [], totalProfit: 0, positiveTotal: 0, hasRing: false });
  });

  it("sorts by profit descending and shares add up to 100", () => {
    const ring = buildProfitRing([svc("CUP", 300), svc("ZELLE", 500), svc("USDT", 200)]);
    expect(ring.rows.map((r) => r.service)).toEqual(["ZELLE", "CUP", "USDT"]);
    expect(ring.rows.map((r) => r.share)).toEqual([0.5, 0.3, 0.2]);
    expect(ring.totalProfit).toBe(1000);
    expect(ring.hasRing).toBe(true);
    expect(ring.rows.every((r) => r.slice)).toBe(true);
  });

  it("a single service fills the whole ring", () => {
    const ring = buildProfitRing([svc("ZELLE", 250)]);
    expect(ring.rows).toEqual([{ service: "ZELLE", profit: 250, share: 1, slice: true }]);
    expect(ring.hasRing).toBe(true);
  });

  it("lists a zero-profit service without a slice", () => {
    const ring = buildProfitRing([svc("ZELLE", 100), svc("CUP", 0)]);
    expect(ring.rows[1]).toEqual({ service: "CUP", profit: 0, share: 0, slice: false });
    expect(ring.rows[0].share).toBe(1);
  });

  it("keeps a negative service out of the ring and out of the percentage base", () => {
    const ring = buildProfitRing([svc("ZELLE", 300), svc("CUP", 100), svc("USDT", -50)]);
    expect(ring.positiveTotal).toBe(400);
    expect(ring.totalProfit).toBe(350);
    expect(ring.rows[0].share).toBe(0.75);
    expect(ring.rows[2]).toEqual({ service: "USDT", profit: -50, share: null, slice: false });
    expect(ring.hasRing).toBe(true);
  });

  it("has no ring when the total profit is zero", () => {
    const ring = buildProfitRing([svc("ZELLE", 0), svc("CUP", 0)]);
    expect(ring.hasRing).toBe(false);
    expect(ring.rows.every((r) => r.share === null)).toBe(true);
    expect(ring.rows.every((r) => !r.slice)).toBe(true);
  });

  it("has no ring when the total profit is negative, even with a positive service", () => {
    const ring = buildProfitRing([svc("ZELLE", 100), svc("CUP", -300)]);
    expect(ring.totalProfit).toBe(-200);
    expect(ring.hasRing).toBe(false);
    expect(ring.rows.every((r) => !r.slice && r.share === null)).toBe(true);
  });
});
