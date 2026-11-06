import { describe, expect, it } from "vitest";
import { isUsdPlanBlocked, mapUsdPanel, visibleUsdPanel } from "./panel";

const line = (over: Record<string, unknown> = {}) => ({
  card_id: "c1", card_name: "Clásica A", last4: "1234", lot_id: "l1", amount_usd: "100", usd_per_usdt: "1.05", ...over,
});

const PLAN = {
  state: "plan", operation_id: "op", estimate: true, cuba_month: "2026-11-01", blocked: false,
  services: [
    {
      service: "CLASICA", needed_usd: 100, planned_usd: 100, missing_usd: 0, blocked: false, invested_usdt: "95.24",
      lines: [line()],
      cards: [{ id: "c1", name: "Clásica A", balance_usd: 400, monthly_limit_usd: 5000, used_this_month_usd: 0, planned_usd: 100 }],
    },
  ],
};

const DONE = {
  state: "completed", operation_id: "op", estimate: false, consumed_usd: "100", invested_usdt: "95.24", cost_gyd: "22666.67", shortfall_usd: 0,
  lines: [{ ...line(), service: "CLASICA", consumed_at: "2026-11-03T10:00:00Z" }],
};

describe("mapUsdPanel", () => {
  it("maps a plan with numbers from strings", () => {
    const read = mapUsdPanel(PLAN);
    expect(read).toMatchObject({ state: "plan", estimate: true, blocked: false, cubaMonth: "2026-11-01" });
    if (read?.state !== "plan") throw new Error("plan expected");
    expect(read.services[0]).toMatchObject({ service: "CLASICA", neededUsd: 100, plannedUsd: 100, missingUsd: 0, blocked: false, investedUsdt: 95.24 });
    expect(read.services[0].lines[0]).toEqual({ cardId: "c1", cardName: "Clásica A", last4: "1234", lotId: "l1", amountUsd: 100, usdPerUsdt: 1.05 });
  });

  it("maps a completed read", () => {
    const read = mapUsdPanel(DONE);
    expect(read).toMatchObject({ state: "completed", estimate: false, consumedUsd: 100, investedUsdt: 95.24, costGyd: 22666.67, shortfallUsd: 0 });
    if (read?.state !== "completed") throw new Error("completed expected");
    expect(read.lines[0]).toMatchObject({ service: "CLASICA", amountUsd: 100, usdPerUsdt: 1.05 });
  });

  it("maps the empty states and rejects unknown payloads", () => {
    for (const state of ["unavailable", "not_usd", "no_inventory", "no_amounts"]) {
      expect(mapUsdPanel({ state, operation_id: "op" })).toEqual({ state });
    }
    expect(mapUsdPanel({ state: "weird" })).toBeNull();
    expect(mapUsdPanel(null)).toBeNull();
    expect(mapUsdPanel("x")).toBeNull();
  });
});

describe("visibleUsdPanel / isUsdPlanBlocked", () => {
  it("shows plan and completed, hides the empty states", () => {
    expect(visibleUsdPanel(mapUsdPanel(PLAN)!)?.state).toBe("plan");
    expect(visibleUsdPanel(mapUsdPanel(DONE)!)?.state).toBe("completed");
    expect(visibleUsdPanel({ state: "not_usd" })).toBeNull();
  });

  it("is blocked only for a plan whose blocked flag is set", () => {
    expect(isUsdPlanBlocked(mapUsdPanel(PLAN)!)).toBe(false);
    const blocked = { ...PLAN, blocked: true, services: [{ ...PLAN.services[0], blocked: true, missing_usd: 50, planned_usd: 50 }] };
    expect(isUsdPlanBlocked(mapUsdPanel(blocked)!)).toBe(true);
    expect(isUsdPlanBlocked(mapUsdPanel(DONE)!)).toBe(false);
    expect(isUsdPlanBlocked(null)).toBe(false);
  });
});
