import { describe, expect, it } from "vitest";
import {
  buildSemanaOverview,
  dayDiff,
  incompleteCount,
  mondayOf,
  openWeekStart,
  percentChange,
  profitByDay,
  profitByService,
  topClients,
  usdtSummary,
  weekTotals,
  type OverviewEntry,
  type PreviousWeekInput,
} from "./semana-overview";

let seq = 0;
function entry(overrides: Partial<OverviewEntry> = {}): OverviewEntry {
  seq += 1;
  return {
    id: `e${seq}`,
    entryDate: "2026-10-27",
    status: "completed",
    service: "ZELLE",
    customerName: "Ana",
    facturadoGyd: 1000,
    invertidoGyd: 900,
    retornoGyd: 100,
    usdtBuyGyd: null,
    missingRates: [],
    ...overrides,
  };
}

describe("dayDiff and mondayOf", () => {
  it("counts whole days between two YYYY-MM-DD days", () => {
    expect(dayDiff("2026-10-26", "2026-10-28")).toBe(2);
    expect(dayDiff("2026-10-30", "2026-11-02")).toBe(3);
    expect(dayDiff("2026-10-28", "2026-10-26")).toBe(-2);
  });

  it("finds the Monday of the week of any day, Sunday belonging to the week that ends on it", () => {
    expect(mondayOf("2026-10-28")).toBe("2026-10-26"); // Wednesday
    expect(mondayOf("2026-10-26")).toBe("2026-10-26"); // Monday
    expect(mondayOf("2026-11-01")).toBe("2026-10-26"); // Sunday
  });
});

describe("openWeekStart", () => {
  it("starts on the Guyana day of the last cut", () => {
    // 2026-10-27T02:00Z is still Monday 26 in Guyana (UTC-4)
    expect(openWeekStart("2026-10-27T02:00:00Z", [entry()])).toEqual({ day: "2026-10-26", fromCut: true });
  });

  it("starts on the earliest live entry when there is no cut", () => {
    const entries = [entry({ entryDate: "2026-10-29" }), entry({ entryDate: "2026-10-27T10:00:00" })];
    expect(openWeekStart(null, entries)).toEqual({ day: "2026-10-27", fromCut: false });
  });

  it("has no start with neither a cut nor entries", () => {
    expect(openWeekStart(null, [])).toEqual({ day: null, fromCut: false });
  });
});

describe("weekTotals", () => {
  it("sums only completed entries: pending, voided and unknown statuses never count", () => {
    const totals = weekTotals([
      entry({ facturadoGyd: 1000, invertidoGyd: 900, retornoGyd: 100 }),
      entry({ facturadoGyd: 500, invertidoGyd: 400, retornoGyd: 100 }),
      entry({ status: "verified_pending", facturadoGyd: 9999, retornoGyd: 9999 }),
      entry({ status: "void", facturadoGyd: 7777, retornoGyd: 7777 }),
    ]);
    expect(totals).toEqual({ facturado: 1500, invertido: 1300, retorno: 200, ops: 2, margin: (200 / 1500) * 100, ticket: 750 });
  });

  it("treats null figures as zero and gives null margin and ticket for an empty week", () => {
    expect(weekTotals([entry({ facturadoGyd: null, invertidoGyd: null, retornoGyd: null })]).facturado).toBe(0);
    expect(weekTotals([])).toEqual({ facturado: 0, invertido: 0, retorno: 0, ops: 0, margin: null, ticket: null });
  });
});

describe("usdtSummary", () => {
  it("adds invertido / buy rate over the entries that have a rate and averages their cost", () => {
    const summary = usdtSummary([
      entry({ invertidoGyd: 2600, usdtBuyGyd: 260 }), // 10 USDT
      entry({ invertidoGyd: 5200, usdtBuyGyd: 260 }), // 20 USDT
      entry({ invertidoGyd: 9999, usdtBuyGyd: null }), // no rate: left out of both sides
    ]);
    expect(summary).toEqual({ usdt: 30, avgCost: 260 });
  });

  it("is null when no entry carries a rate, and skips voided entries", () => {
    expect(usdtSummary([entry({ usdtBuyGyd: null })])).toBeNull();
    expect(usdtSummary([entry({ status: "void", invertidoGyd: 2600, usdtBuyGyd: 260 })])).toBeNull();
  });
});

describe("percentChange", () => {
  it("is the relative change, null without a base", () => {
    expect(percentChange(108, 100)).toBeCloseTo(8);
    expect(percentChange(90, 100)).toBeCloseTo(-10);
    expect(percentChange(50, 0)).toBeNull();
  });
});

describe("profitByDay (the days of the open week)", () => {
  const rows = [
    entry({ entryDate: "2026-10-26", retornoGyd: 50 }),
    entry({ entryDate: "2026-10-26", retornoGyd: 25 }),
    entry({ entryDate: "2026-10-28", retornoGyd: 200 }),
    entry({ entryDate: "2026-10-28", status: "void", retornoGyd: 5000 }),
  ];

  it("starts at the day the week opened, flags today, the best day and the days not reached yet", () => {
    const days = profitByDay(rows, "2026-10-26", "2026-10-28");
    expect(days.map((d) => d.day)).toEqual(["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31"]);
    expect(days[0]).toMatchObject({ retorno: 75, ops: 2, isToday: false, isFuture: false, isMax: false });
    expect(days[2]).toMatchObject({ retorno: 200, ops: 1, isToday: true, isMax: true, isFuture: false });
    expect(days.slice(3).every((d) => d.isFuture)).toBe(true);
  });

  it("follows a week that opened mid-week: it is not the calendar week", () => {
    // Opened Wednesday 14 Oct, today Thursday 15: the chart starts on the 14th, not on Monday the 12th.
    const days = profitByDay([entry({ entryDate: "2026-10-14", retornoGyd: 10 })], "2026-10-14", "2026-10-15");
    expect(days[0]).toMatchObject({ day: "2026-10-14", retorno: 10 });
    expect(days[1]).toMatchObject({ day: "2026-10-15", isToday: true });
  });

  it("counts a Sunday and keeps growing when the week has been open for more than six days", () => {
    const days = profitByDay([entry({ entryDate: "2026-10-18", retornoGyd: 7 })], "2026-10-14", "2026-10-20");
    expect(days.map((d) => d.day)).toEqual(Array.from({ length: 7 }, (_, i) => `2026-10-${14 + i}`));
    expect(days[4]).toMatchObject({ retorno: 7, ops: 1 });
    expect(days.some((d) => d.isFuture)).toBe(false);
  });

  it("shows at most the newest 14 days of a week that has been open for a long time", () => {
    const days = profitByDay([], "2026-09-01", "2026-10-28");
    expect(days).toHaveLength(14);
    expect(days[13]).toMatchObject({ day: "2026-10-28", isToday: true });
  });

  it("starts today when the open week has no known start", () => {
    expect(profitByDay([], null, "2026-10-28")[0].day).toBe("2026-10-28");
  });

  it("flags no best day when every day is empty", () => {
    expect(profitByDay([], "2026-10-26", "2026-10-28").some((d) => d.isMax)).toBe(false);
  });
});

describe("profitByService", () => {
  it("sorts by profit, then name, with the margin per service", () => {
    const rows = profitByService([
      entry({ service: "ZELLE", facturadoGyd: 1000, retornoGyd: 100 }),
      entry({ service: "CUP", facturadoGyd: 1000, retornoGyd: 300 }),
      entry({ service: "CUP", facturadoGyd: 1000, retornoGyd: 100 }),
      entry({ service: "USDT", facturadoGyd: 0, retornoGyd: 100 }),
      entry({ service: "MLC", status: "verified_pending", retornoGyd: 1 }),
    ]);
    expect(rows.map((r) => r.service)).toEqual(["CUP", "USDT", "ZELLE"]);
    expect(rows[0]).toMatchObject({ retorno: 400, facturado: 2000, ops: 2, margin: 20 });
    expect(rows[1]!.margin).toBeNull();
  });
});

describe("topClients", () => {
  it("groups by name ignoring case and spaces, drops blanks, breaks ties by name, caps at 5", () => {
    const rows = topClients([
      entry({ customerName: "Ana", retornoGyd: 100 }),
      entry({ customerName: " ana ", retornoGyd: 50 }),
      entry({ customerName: "Bruno", retornoGyd: 150 }),
      entry({ customerName: "Carla", retornoGyd: 150 }),
      entry({ customerName: null, retornoGyd: 9999 }),
      entry({ customerName: "  ", retornoGyd: 9999 }),
      entry({ customerName: "D", retornoGyd: 10 }),
      entry({ customerName: "E", retornoGyd: 9 }),
      entry({ customerName: "F", retornoGyd: 8 }),
      entry({ customerName: "Void", status: "void", retornoGyd: 9999 }),
    ]);
    expect(rows.map((r) => r.name)).toEqual(["Ana", "Bruno", "Carla", "D", "E"]);
    expect(rows[0]).toMatchObject({ retorno: 150, ops: 2 });
  });
});

describe("incompleteCount", () => {
  it("counts pending and missing-rate lines, never voided ones", () => {
    expect(
      incompleteCount([
        entry(),
        entry({ status: "verified_pending" }),
        entry({ missingRates: ["usdt_buy_gyd"] }),
        entry({ status: "void", missingRates: ["x"] }),
      ]),
    ).toBe(2);
  });
});

describe("buildSemanaOverview", () => {
  const now = new Date("2026-10-28T15:00:00Z"); // Wednesday 28 in Guyana
  const current = [
    entry({ entryDate: "2026-10-26", facturadoGyd: 1000, retornoGyd: 100 }),
    entry({ entryDate: "2026-10-27", facturadoGyd: 1000, retornoGyd: 100 }),
    entry({ entryDate: "2026-10-28", facturadoGyd: 500, retornoGyd: 60 }),
  ];

  it("has no overview for an empty week", () => {
    expect(buildSemanaOverview([], null, null, now).empty).toBe(true);
  });

  it("compares with the previous week at the same elapsed point, not its full total", () => {
    // open week starts Monday 26 -> 2 days elapsed by Wednesday. Previous week starts Monday 19: only 19..21 count.
    const previous: PreviousWeekInput = {
      startDay: "2026-10-19",
      entries: [
        { entryDate: "2026-10-19", facturadoGyd: 1000, retornoGyd: 100 },
        { entryDate: "2026-10-21", facturadoGyd: 1500, retornoGyd: 120 },
        { entryDate: "2026-10-23", facturadoGyd: 9000, retornoGyd: 900 }, // after the same point: left out
      ],
    };
    const overview = buildSemanaOverview(current, "2026-10-26T12:00:00Z", previous, now);
    expect(overview.empty).toBe(false);
    expect(overview.totals.retorno).toBe(260);
    expect(overview.comparison).toEqual({ profitPct: percentChange(260, 220), facturadoPct: percentChange(2500, 2500) });
    expect(overview.startDay).toBe("2026-10-26");
    expect(overview.today).toMatchObject({ ops: 1, facturado: 500, retorno: 60 });
  });

  it("falls back to the earliest entry of the previous week when its start is unknown", () => {
    const previous: PreviousWeekInput = {
      startDay: null,
      entries: [
        { entryDate: "2026-10-20", facturadoGyd: 1000, retornoGyd: 130 },
        { entryDate: "2026-10-23", facturadoGyd: 9000, retornoGyd: 900 },
      ],
    };
    const overview = buildSemanaOverview(current, "2026-10-26T12:00:00Z", previous, now);
    expect(overview.comparison?.profitPct).toBeCloseTo(((260 - 130) / 130) * 100);
  });

  it("has no comparison without a previous week or when it had nothing at that point", () => {
    expect(buildSemanaOverview(current, null, null, now).comparison).toBeNull();
    const empty: PreviousWeekInput = { startDay: "2026-10-19", entries: [] };
    expect(buildSemanaOverview(current, null, empty, now).comparison).toBeNull();
  });
});
