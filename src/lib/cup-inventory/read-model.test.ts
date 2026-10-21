// The report RPC speaks snake_case jsonb with numerics that may arrive as numbers or strings;
// the app speaks camelCase numbers.
import { describe, expect, it } from "vitest";
import { mapBalanceResult, mapCard, mapConsumption, mapLot, mapReport } from "./read-model";

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
  consumptions_today: [
    {
      id: "k-1",
      consumed_at: "2026-10-14T15:30:00Z",
      amount_cup: "50000",
      lot_id: "lot-1",
      lot_rate_cup_per_usdt: "960",
      operation_id: "op-1",
      entry_id: "entry-1",
      source: "completed_operation",
      customer_name: "Cliente Uno",
    },
    {
      id: "k-2",
      consumed_at: "2026-10-14T16:00:00Z",
      amount_cup: 15000,
      lot_id: "lot-1",
      lot_rate_cup_per_usdt: 960,
      operation_id: null,
      entry_id: "entry-2",
      source: "manual",
      customer_name: null,
    },
  ],
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
      exhausted: false,
      adjusted: false,
      adjustmentNetCup: 0,
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

  it("maps today's consumptions with time, amount, lot rate, source and customer", () => {
    const { consumptionsToday } = mapCard(CARD_ROW);
    expect(consumptionsToday).toEqual([
      {
        id: "k-1",
        consumedAt: "2026-10-14T15:30:00Z",
        amountCup: 50000,
        lotId: "lot-1",
        lotRateCupPerUsdt: 960,
        operationId: "op-1",
        entryId: "entry-1",
        source: "completed_operation",
        customerName: "Cliente Uno",
        kind: "operacion",
        reason: null,
      },
      {
        id: "k-2",
        consumedAt: "2026-10-14T16:00:00Z",
        amountCup: 15000,
        lotId: "lot-1",
        lotRateCupPerUsdt: 960,
        operationId: null,
        entryId: "entry-2",
        source: "manual",
        customerName: null,
        kind: "operacion",
        reason: null,
      },
    ]);
  });

  it("a card from an older report without consumptions has none", () => {
    expect(mapCard({ ...CARD_ROW, consumptions_today: undefined }).consumptionsToday).toEqual([]);
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

describe("lot history (migration 256)", () => {
  it("a used-up lot is exhausted; an adjusted lot carries its net adjustment", () => {
    expect(mapLot({ ...LOT_ROW, remaining_cup: 0, editable: false, agotado: true, adjusted: true, adjustment_net_cup: "17160" })).toMatchObject({
      remainingCup: 0,
      exhausted: true,
      adjusted: true,
      adjustmentNetCup: 17160,
    });
  });

  it("older payloads (no agotado / adjusted) still map: exhausted comes from remaining 0, adjusted is false", () => {
    expect(mapLot(LOT_ROW)).toMatchObject({ exhausted: false, adjusted: false, adjustmentNetCup: 0 });
    expect(mapLot({ ...LOT_ROW, remaining_cup: 0 })).toMatchObject({ exhausted: true });
  });

  it("a movement carries its kind and reason; no kind means an operation", () => {
    const base = { id: "k", consumed_at: "2026-10-14T15:30:00Z", amount_cup: "5000", lot_id: "lot-1", lot_rate_cup_per_usdt: 960 };
    expect(mapConsumption({ ...base, kind: "ajuste", reason: "conteo real" })).toMatchObject({ kind: "ajuste", reason: "conteo real", amountCup: 5000 });
    expect(mapConsumption({ ...base, kind: "manual" })).toMatchObject({ kind: "manual", reason: null });
    expect(mapConsumption(base)).toMatchObject({ kind: "operacion", reason: null });
    expect(mapConsumption({ ...base, amount_cup: "-8000", kind: "ajuste" }).amountCup).toBe(-8000);
  });

  it("maps the adjustment result", () => {
    expect(
      mapBalanceResult({ card_id: "c1", saldo_anterior: "240000", saldo_nuevo: 222840, movimientos: [{ lot_id: "l1", amount_cup: "-17160" }] }),
    ).toEqual({ cardId: "c1", previousBalanceCup: 240000, newBalanceCup: 222840, movements: [{ lotId: "l1", amountCup: -17160 }] });
    expect(mapBalanceResult({ card_id: "c1", saldo_anterior: 5, saldo_nuevo: 5 }).movements).toEqual([]);
  });
});
