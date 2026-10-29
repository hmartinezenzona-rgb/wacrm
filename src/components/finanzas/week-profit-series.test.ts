// Pure shaping of the archived week summaries into the "Ganancia por semana" line.

import { describe, expect, it } from "vitest";
import type { CalculatorWeekSummary } from "@/lib/calculator/weeks";
import { showWeekChart, weeklyProfitSeries, WEEKS_SHOWN } from "./week-profit-series";

function week(id: string, cutAt: string, manualRetorno: number, chatRetorno: number, periodo = ""): CalculatorWeekSummary {
  return {
    id,
    cutAt,
    periodo,
    manualTotals: { facturadoGyd: 100, invertidoGyd: 40, retornoGyd: manualRetorno },
    chatTotals: { facturadoGyd: 200, invertidoGyd: 50, retornoGyd: chatRetorno, count: 2 },
  };
}

describe("weeklyProfitSeries", () => {
  it("orders oldest to newest whatever order the API returns, summing manual and chat totals", () => {
    const series = weeklyProfitSeries([
      week("b", "2026-10-12T15:00:00.000Z", 10, 20, "Semana 2"),
      week("a", "2026-10-05T15:00:00.000Z", 1, 2),
    ]);
    expect(series.map((p) => p.id)).toEqual(["a", "b"]);
    expect(series[1]).toMatchObject({ facturado: 300, retorno: 30, periodo: "Semana 2", cutDate: "2026-10-12", label: "12 oct" });
  });

  it("keeps only the last 12 weeks", () => {
    const weeks = Array.from({ length: 15 }, (_, i) =>
      week(`w${i}`, new Date(Date.UTC(2026, 0, 1 + i * 7, 15)).toISOString(), i, 0),
    );
    const series = weeklyProfitSeries(weeks);
    expect(series).toHaveLength(WEEKS_SHOWN);
    expect(series[0]!.id).toBe("w3");
    expect(series.at(-1)!.id).toBe("w14");
  });
});

describe("showWeekChart", () => {
  it("hides the line with fewer than two weeks", () => {
    expect(showWeekChart([])).toBe(false);
    expect(showWeekChart(weeklyProfitSeries([week("a", "2026-10-05T15:00:00.000Z", 1, 1)]))).toBe(false);
  });
  it("shows it from two weeks on", () => {
    expect(showWeekChart(weeklyProfitSeries([week("a", "2026-10-05T15:00:00.000Z", 1, 1), week("b", "2026-10-12T15:00:00.000Z", 1, 1)]))).toBe(true);
  });
});
