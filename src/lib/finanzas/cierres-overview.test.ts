import { describe, expect, it } from "vitest";
import {
  buildCierresOverview,
  buildClosedWeeks,
  filterWeeksByPeriod,
  type ClosedWeekInput,
} from "./cierres-overview";

let seq = 0;
/** A week whose profit is `retorno`; entries default to two on the given days. */
function input(overrides: Partial<ClosedWeekInput> & { cutAt: string }): ClosedWeekInput {
  seq += 1;
  return {
    id: `w${seq}`,
    periodo: `SEMANA ${seq}`,
    facturado: 1000,
    invertido: 900,
    retorno: 100,
    entries: null,
    ...overrides,
  };
}

const entry = (entryDate: string, service: string, retornoGyd: number | null, facturadoGyd: number | null = 1000) => ({
  entryDate,
  service,
  facturadoGyd,
  retornoGyd,
});

describe("buildClosedWeeks", () => {
  it("orders newest cut first and carries the stored totals and margin", () => {
    const weeks = buildClosedWeeks([
      input({ id: "old", cutAt: "2026-10-05T15:00:00Z", facturado: 2000, retorno: 200 }),
      input({ id: "new", cutAt: "2026-10-12T15:00:00Z", facturado: 1000, retorno: 150 }),
    ]);
    expect(weeks.map((w) => w.id)).toEqual(["new", "old"]);
    expect(weeks[0]).toMatchObject({ facturado: 1000, retorno: 150, margin: 15 });
    expect(weeks[1]!.margin).toBe(10);
  });

  it("takes the dates, ops, best day and top service from the entries, in Guyana days", () => {
    const [week] = buildClosedWeeks([
      input({
        cutAt: "2026-10-26T12:00:00Z",
        entries: [
          entry("2026-10-20T09:00:00", "ZELLE", 30),
          entry("2026-10-21", "CUP", 50),
          entry("2026-10-21", "CUP", 20),
          entry("2026-10-24", "ZELLE", 10),
        ],
      }),
    ]);
    expect(week).toMatchObject({
      startDay: "2026-10-20",
      endDay: "2026-10-24",
      ops: 4,
      bestDay: { day: "2026-10-21", retorno: 70 },
      topService: "CUP",
    });
  });

  it("falls back to the cut day (Guyana) and leaves entry figures empty when the week has no entries", () => {
    // 2026-10-27T02:00Z is still Monday 26 in Guyana (UTC-4)
    const [week] = buildClosedWeeks([input({ cutAt: "2026-10-27T02:00:00Z", entries: null })]);
    expect(week).toMatchObject({ startDay: null, endDay: "2026-10-26", ops: null, bestDay: null, topService: null });
    const [empty] = buildClosedWeeks([input({ cutAt: "2026-10-27T02:00:00Z", entries: [] })]);
    expect(empty).toMatchObject({ ops: 0, bestDay: null, topService: null, endDay: "2026-10-26" });
  });

  it("gives each week its change against the next older archived week, null without a base", () => {
    const weeks = buildClosedWeeks([
      input({ cutAt: "2026-10-05T15:00:00Z", retorno: 0 }),
      input({ cutAt: "2026-10-12T15:00:00Z", retorno: 200 }),
      input({ cutAt: "2026-10-19T15:00:00Z", retorno: 250 }),
    ]);
    expect(weeks.map((w) => w.vsPrevious)).toEqual([25, null, null]); // newest +25 %, then base 0, then none older
  });

  it("margin is null when nothing was billed", () => {
    expect(buildClosedWeeks([input({ cutAt: "2026-10-05T15:00:00Z", facturado: 0, retorno: 0 })])[0]!.margin).toBeNull();
  });
});

describe("filterWeeksByPeriod", () => {
  const weeks = buildClosedWeeks(
    Array.from({ length: 14 }, (_, i) => {
      const cut = new Date(Date.UTC(2026, 6, 6 + i * 7, 15)); // Mondays from 6 Jul 2026
      return input({ id: `w${i}`, cutAt: cut.toISOString() });
    }),
  );
  const ids = (list: { id: string }[]) => list.map((w) => w.id);

  it("last12 keeps the newest twelve", () => {
    expect(filterWeeksByPeriod(weeks, "last12", "2026-10-10")).toHaveLength(12);
    expect(filterWeeksByPeriod(weeks, "last12", "2026-10-10")[0]!.id).toBe("w13");
  });

  it("all keeps everything", () => {
    expect(filterWeeksByPeriod(weeks, "all", "2026-10-10")).toHaveLength(14);
  });

  it("this month and last month go by the day the week ended (Guyana)", () => {
    const today = "2026-10-10";
    const october = filterWeeksByPeriod(weeks, "thisMonth", today);
    const september = filterWeeksByPeriod(weeks, "lastMonth", today);
    expect(ids(october)).toEqual(["w13"]); // 5 Oct
    expect(ids(september)).toEqual(["w12", "w11", "w10", "w9"]); // 28, 21, 14 and 7 Sep
  });

  it("last month across a year boundary", () => {
    const jan = buildClosedWeeks([
      input({ id: "dec", cutAt: "2025-12-29T15:00:00Z" }),
      input({ id: "jan", cutAt: "2026-01-05T15:00:00Z" }),
    ]);
    expect(ids(filterWeeksByPeriod(jan, "lastMonth", "2026-01-10"))).toEqual(["dec"]);
  });
});

describe("buildCierresOverview", () => {
  const mk = (profits: number[]) =>
    buildClosedWeeks(
      profits.map((retorno, i) =>
        input({
          id: `w${i}`,
          cutAt: new Date(Date.UTC(2026, 8, 7 + i * 7, 15)).toISOString(),
          facturado: retorno * 10,
          invertido: retorno * 9,
          retorno,
          entries: [entry("2026-09-08", i % 2 ? "CUP" : "ZELLE", retorno)],
        }),
      ),
    );

  it("is empty without weeks", () => {
    expect(buildCierresOverview([])).toMatchObject({ count: 0, change: null, best: null, worst: null, chart: [], services: [] });
  });

  it("totals, average per week, ops per week and average margin over the period", () => {
    const o = buildCierresOverview(mk([100, 200, 300]));
    expect(o.totals).toEqual({ retorno: 600, facturado: 6000, invertido: 5400 });
    expect(o.avgProfit).toBe(200);
    expect(o.avgOps).toBe(1);
    expect(o.margin).toBe(10);
  });

  it("best and worst week by profit; the worst is hidden with a single week", () => {
    const o = buildCierresOverview(mk([100, 300, 200]));
    expect(o.best!.retorno).toBe(300);
    expect(o.worst!.retorno).toBe(100);
    expect(buildCierresOverview(mk([100])).worst).toBeNull();
    expect(buildCierresOverview(mk([100])).best!.retorno).toBe(100);
  });

  it("compares the last 6 weeks with the previous 6, or equal halves when there are fewer", () => {
    // oldest to newest: six weeks of 100 then six of 150 -> +50 %
    const twelve = buildCierresOverview(mk([...Array(6).fill(100), ...Array(6).fill(150)]));
    expect(twelve.change).toEqual({ pct: 50, weeks: 6 });
    const four = buildCierresOverview(mk([100, 100, 200, 200]));
    expect(four.change).toEqual({ pct: 100, weeks: 2 });
    const three = buildCierresOverview(mk([100, 50, 200]));
    expect(three.change).toEqual({ pct: 300, weeks: 1 }); // floor(3/2) = 1: the newest (200) against the one before (50)
  });

  it("hides the change with fewer than two weeks or a zero base", () => {
    expect(buildCierresOverview(mk([100])).change).toBeNull();
    expect(buildCierresOverview(mk([0, 100])).change).toBeNull();
  });

  it("chart runs oldest to newest with the average", () => {
    const o = buildCierresOverview(mk([100, 200, 300]));
    expect(o.chart.map((p) => p.retorno)).toEqual([100, 200, 300]);
    expect(o.average).toBe(200);
  });

  it("profit by service over the period, highest first, with its share", () => {
    const o = buildCierresOverview(mk([100, 200, 300])); // ZELLE 100 + 300, CUP 200
    expect(o.services).toEqual([
      { service: "ZELLE", retorno: 400, share: (400 / 600) * 100 },
      { service: "CUP", retorno: 200, share: (200 / 600) * 100 },
    ]);
  });
});
