// The report RPC speaks snake_case jsonb with numerics that may arrive as numbers or strings;
// the app speaks camelCase numbers.
import { describe, expect, it } from "vitest";
import { mapCard, mapLot, mapReport } from "./read-model";

const LOT_ROW = {
  id: "lot-1",
  amount_cup: "500000",
  remaining_cup: 500000,
  rate_cup_per_usdt: "960",
  loaded_at: "2026-10-14T12:00:00Z",
  note: "compra A",
  editable: true,
};

const CARD_ROW = {
  id: "card-1",
  name: "Tarjeta A",
  last4: "1234",
  priority: 1,
  active: true,
  daily_limit_cup: "120000",
  balance_cup: "500000",
  used_today_cup: 0,
  remaining_limit_today_cup: "120000",
  lots: [LOT_ROW],
};

describe("mapLot", () => {
  it("camelCases the lot and turns numerics into numbers", () => {
    expect(mapLot(LOT_ROW)).toEqual({
      id: "lot-1",
      amountCup: 500000,
      remainingCup: 500000,
      rateCupPerUsdt: 960,
      loadedAt: "2026-10-14T12:00:00Z",
      note: "compra A",
      editable: true,
    });
  });

  it("keeps a missing note as null and a missing editable flag as false", () => {
    const lot = mapLot({ ...LOT_ROW, note: undefined, editable: undefined });
    expect(lot.note).toBeNull();
    expect(lot.editable).toBe(false);
  });
});

describe("mapCard", () => {
  it("maps the card with its lots", () => {
    const card = mapCard(CARD_ROW);
    expect(card).toMatchObject({
      id: "card-1",
      name: "Tarjeta A",
      last4: "1234",
      priority: 1,
      active: true,
      dailyLimitCup: 120000,
      balanceCup: 500000,
      usedTodayCup: 0,
      remainingLimitTodayCup: 120000,
    });
    expect(card.lots).toHaveLength(1);
    expect(card.lots[0].rateCupPerUsdt).toBe(960);
  });

  it("tolerates a card without lots and without last4", () => {
    const card = mapCard({ ...CARD_ROW, last4: null, lots: undefined });
    expect(card.last4).toBeNull();
    expect(card.lots).toEqual([]);
  });
});

describe("mapReport", () => {
  it("maps the cuba day and keeps the card order of the RPC", () => {
    const report = mapReport({
      cuba_day: "2026-10-14",
      cards: [CARD_ROW, { ...CARD_ROW, id: "card-2", name: "Tarjeta B", priority: 2 }],
    });
    expect(report.cubaDay).toBe("2026-10-14");
    expect(report.cards.map((c) => c.id)).toEqual(["card-1", "card-2"]);
  });

  it("an empty or null payload is an empty report", () => {
    expect(mapReport(null)).toEqual({ cubaDay: null, cards: [] });
  });
});
