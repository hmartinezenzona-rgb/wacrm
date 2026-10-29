// Pure shaping of the financial close into the Cierres profit charts (Finanzas > Cierres).

import { describe, expect, it } from "vitest";
import type { CloseAggregate } from "./read-model";
import { profitByDaySeries, profitByServiceSeries, showDayChart, showServiceChart } from "./profit-series";

const agg = (operations: number, facturado: number, invertido: number, retorno: number): CloseAggregate => ({
  operations,
  facturadoGyd: facturado,
  invertidoGyd: invertido,
  retornoGyd: retorno,
});

describe("profitByDaySeries", () => {
  it("returns one point per day, oldest first, with the profit and the operation count", () => {
    const series = profitByDaySeries([
      { day: "2026-09-22", ...agg(3, 900, 700, 200) },
      { day: "2026-09-21", ...agg(1, 500, 400, 100) },
    ]);
    expect(series).toEqual([
      { day: "2026-09-21", label: "21 sep", retorno: 100, operations: 1 },
      { day: "2026-09-22", label: "22 sep", retorno: 200, operations: 3 },
    ]);
  });

  it("keeps a negative profit as a negative value", () => {
    const series = profitByDaySeries([{ day: "2026-09-21", ...agg(1, 100, 150, -50) }]);
    expect(series[0]!.retorno).toBe(-50);
  });

  it("does not mutate its input", () => {
    const input = [
      { day: "2026-09-22", ...agg(1, 1, 1, 1) },
      { day: "2026-09-21", ...agg(1, 1, 1, 1) },
    ];
    profitByDaySeries(input);
    expect(input[0]!.day).toBe("2026-09-22");
  });
});

describe("showDayChart", () => {
  it("hides the chart with no days or a single day", () => {
    expect(showDayChart([])).toBe(false);
    expect(showDayChart([{ day: "2026-09-21", label: "21 sep", retorno: 5, operations: 1 }])).toBe(false);
  });
  it("shows it from two days on", () => {
    const point = { day: "2026-09-21", label: "21 sep", retorno: 5, operations: 1 };
    expect(showDayChart([point, { ...point, day: "2026-09-22" }])).toBe(true);
  });
});

describe("profitByServiceSeries", () => {
  it("sorts by profit, highest first, and carries the tooltip figures", () => {
    const series = profitByServiceSeries([
      { service: "CUP", ...agg(1, 1000, 700, 300) },
      { service: "ZELLE", ...agg(2, 2000, 1500, 500) },
      { service: "USDT", ...agg(1, 400, 500, -100) },
    ]);
    expect(series.map((s) => s.service)).toEqual(["ZELLE", "CUP", "USDT"]);
    expect(series[0]).toEqual({
      service: "ZELLE",
      facturado: 2000,
      invertido: 1500,
      retorno: 500,
      margin: "25.0",
      operations: 2,
    });
  });

  it("breaks a tie by service name so the order is stable", () => {
    const series = profitByServiceSeries([
      { service: "B", ...agg(1, 10, 5, 5) },
      { service: "A", ...agg(1, 10, 5, 5) },
    ]);
    expect(series.map((s) => s.service)).toEqual(["A", "B"]);
  });

  it("has no margin when nothing was billed", () => {
    expect(profitByServiceSeries([{ service: "A", ...agg(1, 0, 0, 0) }])[0]!.margin).toBeNull();
  });
});

describe("showServiceChart", () => {
  it("needs at least two services to compare", () => {
    expect(showServiceChart([])).toBe(false);
    expect(showServiceChart([{ service: "A", facturado: 1, invertido: 1, retorno: 0, margin: null, operations: 1 }])).toBe(false);
  });
});
