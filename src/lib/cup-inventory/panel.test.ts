import { describe, expect, it } from "vitest";
import {
  groupConsumptionsByCard,
  groupPlanByCard,
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

describe("groupPlanByCard", () => {
  const plan = mapCupPanel(planPayload) as CupPanelPlan;

  it("groups by card in order of first appearance: one total per card, no beneficiary rows", () => {
    const { cards, missingText } = groupPlanByCard(plan);
    expect(cards.map((c) => [c.name, c.last4, c.totalText])).toEqual([
      ["Tarjeta A", "1111", sp("120 000")],
      ["Tarjeta B", null, sp("30 000")],
    ]);
    expect(cards[0]).not.toHaveProperty("rows");
    expect(missingText).toBeNull();
  });

  it("adds up two lots of the same card into one total", () => {
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
    const { cards } = groupPlanByCard(merged);
    expect(cards).toHaveLength(1);
    expect(cards[0].totalText).toBe(sp("100 000"));
  });

  it("sums the CUP missing across beneficiaries into one text", () => {
    const short = mapCupPanel({
      ...planPayload,
      missing_cup: 90000,
      beneficiaries: [
        { ...planPayload.beneficiaries[0], amount_cup: 120000, missing_cup: 70000, lines: [{ ...planPayload.beneficiaries[0].lines[0], amount_cup: 50000 }] },
        { ...planPayload.beneficiaries[1], amount_cup: 50000, missing_cup: 20000, lines: [{ ...planPayload.beneficiaries[1].lines[0], amount_cup: 30000 }] },
      ],
    }) as CupPanelPlan;
    const { cards, missingText } = groupPlanByCard(short);
    expect(cards[0].totalText).toBe(sp("80 000"));
    expect(missingText).toBe(sp("90 000"));
  });
});

describe("groupConsumptionsByCard", () => {
  it("groups the consumptions by card with its total only", () => {
    const done = mapCupPanel({
      state: "completed",
      consumed_cup: 100000,
      cup_rate: 987.9612,
      lines: [
        { card_id: "A", card_name: "Tarjeta A", last4: "1111", lot_id: "l1", amount_cup: 70000, lot_rate: 960, consumed_at: "x" },
        { card_id: "B", card_name: "Tarjeta B", last4: "2222", lot_id: "l2", amount_cup: 20000, lot_rate: 1060, consumed_at: "x" },
        { card_id: "B", card_name: "Tarjeta B", last4: "2222", lot_id: "l3", amount_cup: 10000, lot_rate: 1070, consumed_at: "x" },
      ],
    });
    if (!done || done.state !== "completed") throw new Error("expected completed");
    const cards = groupConsumptionsByCard(done);
    expect(cards.map((c) => [c.name, c.last4, c.totalText])).toEqual([
      ["Tarjeta A", "1111", sp("70 000")],
      ["Tarjeta B", "2222", sp("30 000")],
    ]);
    expect(cards[1]).not.toHaveProperty("rows");
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
