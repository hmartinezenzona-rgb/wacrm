import { describe, expect, it } from "vitest";
import { mapWeek, mapWeekSummary, type CalculatorWeekRow } from "./weeks";

const ROW: CalculatorWeekRow = {
  id: "week-1",
  cut_at: "2026-10-03T12:00:00+00:00",
  raw_text: "5 zelle 100",
  period_label: "SEMANA 1",
  manual_totals: { facturado_gyd: 1300.5, invertido_gyd: 1200, retorno_gyd: 100.5 },
  chat_totals: { count: 2, facturado_gyd: "39000", invertido_gyd: 36000, retorno_gyd: 3000 },
  entries: [
    {
      id: "e1", operation_id: "op1", service: "ZELLE", customer_name: "Raúl", amount: "100", amount_currency: "USD",
      entry_date: "2026-10-01", facturado_gyd: 26000, invertido_gyd: 24000, retorno_gyd: 2000,
    },
  ],
};

describe("mapWeekSummary", () => {
  it("maps the cut, the period and both sets of totals to numbers", () => {
    expect(mapWeekSummary(ROW)).toEqual({
      id: "week-1",
      cutAt: "2026-10-03T12:00:00+00:00",
      periodo: "SEMANA 1",
      manualTotals: { facturadoGyd: 1300.5, invertidoGyd: 1200, retornoGyd: 100.5 },
      chatTotals: { count: 2, facturadoGyd: 39000, invertidoGyd: 36000, retornoGyd: 3000 },
    });
  });

  it("falls back to zeros for missing or non-finite totals", () => {
    const summary = mapWeekSummary({ ...ROW, manual_totals: {}, chat_totals: { count: "x" } });
    expect(summary.manualTotals).toEqual({ facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 });
    expect(summary.chatTotals).toEqual({ count: 0, facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 });
  });
});

describe("mapWeek", () => {
  it("adds the archived text and the entries, shaped like the chat table rows (completed, no missing rates)", () => {
    const week = mapWeek(ROW);
    expect(week.rawText).toBe("5 zelle 100");
    expect(week.entries).toEqual([
      {
        id: "e1", operationId: "op1", status: "completed", service: "ZELLE", customerName: "Raúl", amount: 100,
        amountCurrency: "USD", entryDate: "2026-10-01", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, missingRates: [],
      },
    ]);
    expect(week.periodo).toBe("SEMANA 1");
  });

  it("an archive without entries reads as an empty list", () => {
    expect(mapWeek({ ...ROW, entries: null as never }).entries).toEqual([]);
  });
});
