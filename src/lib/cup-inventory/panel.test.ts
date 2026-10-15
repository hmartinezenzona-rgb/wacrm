import { describe, expect, it } from "vitest";
import {
  buildPlanLines,
  buildUsedLines,
  cardLabel,
  mapCupPanel,
  visibleCupPanel,
  type CupPanelPlan,
} from "./panel";

// The app groups digits with U+202F (see format-number.ts).
const sp = (text: string) => text.replace(/ /g, "\u202f");

const planPayload = {
  state: "plan",
  operation_id: "op-1",
  estimate: true,
  cuba_day: "2026-10-15",
  total_cup: 150000,
  planned_cup: 150000,
  missing_cup: 0,
  effective_rate: 975.5,
  beneficiaries: [
    {
      beneficiary_id: "b1",
      position: 1,
      name: "Ana",
      amount_cup: 100000,
      missing_cup: 0,
      lines: [{ card_id: "A", card_name: "Tarjeta A", last4: "1111", lot_id: "l1", amount_cup: 100000, lot_rate: 960 }],
    },
    {
      beneficiary_id: "b2",
      position: 2,
      name: null,
      amount_cup: 50000,
      missing_cup: 0,
      lines: [
        { card_id: "A", card_name: "Tarjeta A", last4: "1111", lot_id: "l1", amount_cup: 20000, lot_rate: 960 },
        { card_id: "B", card_name: "Tarjeta B", last4: null, lot_id: "l2", amount_cup: 30000, lot_rate: 1060 },
      ],
    },
  ],
};

describe("cardLabel", () => {
  it("adds the last 4 digits when there are some", () => {
    expect(cardLabel("Tarjeta A", "1111")).toBe("Tarjeta A (…1111)");
    expect(cardLabel("Tarjeta B", null)).toBe("Tarjeta B");
    expect(cardLabel("Tarjeta B", "")).toBe("Tarjeta B");
  });
});

describe("mapCupPanel", () => {
  it("maps a plan to camelCase", () => {
    const read = mapCupPanel(planPayload) as CupPanelPlan;
    expect(read.state).toBe("plan");
    expect(read.totalCup).toBe(150000);
    expect(read.missingCup).toBe(0);
    expect(read.beneficiaries[1].lines[1]).toMatchObject({ cardName: "Tarjeta B", last4: null, amountCup: 30000, lotRate: 1060 });
  });

  it("maps a completed read", () => {
    const read = mapCupPanel({
      state: "completed",
      estimate: false,
      consumed_cup: 40000,
      cup_rate: 1060,
      lines: [{ card_id: "B", card_name: "Tarjeta B", last4: "2222", lot_id: "l2", amount_cup: 40000, lot_rate: 1060, consumed_at: "2026-10-15T10:00:00Z" }],
    });
    expect(read).toMatchObject({ state: "completed", consumedCup: 40000, cupRate: 1060 });
  });

  it("keeps the explicit empty states", () => {
    for (const state of ["not_cup", "no_inventory", "no_amounts", "unavailable"]) {
      expect(mapCupPanel({ state })).toEqual({ state });
    }
  });

  it("rejects what is not a known payload", () => {
    expect(mapCupPanel(null)).toBeNull();
    expect(mapCupPanel({ state: "weird" })).toBeNull();
    expect(mapCupPanel({ state: "plan", beneficiaries: "nope" })).toBeNull();
  });
});

describe("buildPlanLines", () => {
  const plan = mapCupPanel(planPayload) as CupPanelPlan;

  it("shows one line per card, so a beneficiary across two cards has two lines", () => {
    const lines = buildPlanLines(plan);
    expect(lines.map((l) => [l.position, l.beneficiary, l.amountText, l.card])).toEqual([
      [1, "Ana", sp("100 000"), "Tarjeta A (…1111)"],
      [2, null, sp("20 000"), "Tarjeta A (…1111)"],
      [2, null, sp("30 000"), "Tarjeta B"],
    ]);
  });

  it("merges two lots of the same card into one line", () => {
    const merged = mapCupPanel({
      ...planPayload,
      beneficiaries: [
        {
          ...planPayload.beneficiaries[0],
          lines: [
            { card_id: "A", card_name: "Tarjeta A", last4: "1111", lot_id: "l1", amount_cup: 30000, lot_rate: 900 },
            { card_id: "A", card_name: "Tarjeta A", last4: "1111", lot_id: "l2", amount_cup: 70000, lot_rate: 1000 },
          ],
        },
      ],
    }) as CupPanelPlan;
    expect(buildPlanLines(merged).map((l) => l.amountText)).toEqual([sp("100 000")]);
  });

  it("adds a no-card line for the part of a beneficiary the plan could not place", () => {
    const short = mapCupPanel({
      ...planPayload,
      missing_cup: 70000,
      beneficiaries: [{ ...planPayload.beneficiaries[0], amount_cup: 120000, missing_cup: 70000, lines: [{ ...planPayload.beneficiaries[0].lines[0], amount_cup: 50000 }] }],
    }) as CupPanelPlan;
    const lines = buildPlanLines(short);
    expect(lines).toHaveLength(2);
    expect(lines[1]).toMatchObject({ card: null, amountText: sp("70 000") });
  });
});

describe("buildUsedLines", () => {
  it("lists card, amount and lot rate per consumption", () => {
    const done = mapCupPanel({
      state: "completed",
      consumed_cup: 100000,
      cup_rate: 987.9612,
      lines: [
        { card_id: "A", card_name: "Tarjeta A", last4: "1111", lot_id: "l1", amount_cup: 70000, lot_rate: 960, consumed_at: "x" },
        { card_id: "B", card_name: "Tarjeta B", last4: "2222", lot_id: "l2", amount_cup: 30000, lot_rate: 1060, consumed_at: "x" },
      ],
    });
    if (!done || done.state !== "completed") throw new Error("expected completed");
    expect(buildUsedLines(done).map((l) => [l.card, l.amountText, l.rateText])).toEqual([
      ["Tarjeta A (…1111)", sp("70 000"), "960"],
      ["Tarjeta B (…2222)", sp("30 000"), sp("1 060")],
    ]);
  });
});

describe("visibleCupPanel", () => {
  it("hides the empty states, a failed read and lists with nothing to show", () => {
    expect(visibleCupPanel(null)).toBeNull();
    expect(visibleCupPanel({ state: "not_cup" })).toBeNull();
    expect(visibleCupPanel(mapCupPanel({ ...planPayload, beneficiaries: [] }))).toBeNull();
    expect(visibleCupPanel(mapCupPanel({ state: "completed", consumed_cup: 0, cup_rate: null, lines: [] }))).toBeNull();
    expect(visibleCupPanel(mapCupPanel(planPayload))?.state).toBe("plan");
  });
});
