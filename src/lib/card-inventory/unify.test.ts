import { describe, expect, it } from "vitest";
import type { InventoryCard } from "@/lib/cup-inventory/read-model";
import type { UsdCard } from "@/lib/usd-inventory/read-model";
import { costPerUsd, filterCards, limitPercent, profitPerUsd, serviceTotals, unifyCards } from "./unify";

const cupCard = (over: Partial<InventoryCard> = {}): InventoryCard => ({
  id: "cup-1", name: "Eliaba", last4: "6118", priority: 1, active: true, dailyLimitCup: 120000, balanceCup: 240000,
  usedTodayCup: 30000, remainingLimitTodayCup: 90000,
  lots: [{ id: "l-c", amountCup: 240000, remainingCup: 240000, rateCupPerUsdt: 960, loadedAt: "2026-11-01T10:00:00Z", note: "n", editable: true, exhausted: false, adjusted: false, adjustmentNetCup: 0 }],
  consumptionsToday: [{ id: "m-c", consumedAt: "2026-11-02T10:00:00Z", amountCup: 30000, lotId: "l-c", lotRateCupPerUsdt: 960, operationId: "op", entryId: "e", source: "completed_operation", customerName: "Ana", kind: "operacion", reason: null }],
  ...over,
});
const usdCard = (over: Partial<UsdCard> = {}): UsdCard => ({
  id: "usd-1", service: "CLASICA", name: "Clásica A", last4: "1234", priority: 1, active: true, monthlyLimitUsd: 5000, balanceUsd: 400,
  usedThisMonthUsd: 100, remainingMonthUsd: 4900,
  lots: [{ id: "l-u", amountUsd: 500, remainingUsd: 400, usdtPaid: 476.19, usdPerUsdt: 1.05, loadedAt: "2026-11-01T10:00:00Z", note: null, editable: false, exhausted: false, adjusted: false, adjustmentNetUsd: 0 }],
  consumptionsMonth: [{ id: "m-u", consumedAt: "2026-11-02T10:00:00Z", amountUsd: 100, lotId: "l-u", lotUsdPerUsdt: 1.05, operationId: "op", entryId: "e", source: "completed_operation", customerName: "Bea", kind: "operacion", reason: null }],
  ...over,
});

describe("unifyCards", () => {
  it("orders CUP first, then Clásica, then Tropical, keeping each list's order", () => {
    const cards = unifyCards(
      [cupCard({ id: "c1" }), cupCard({ id: "c2" })],
      [usdCard({ id: "t1", service: "TROPICAL" }), usdCard({ id: "k1" })],
    );
    expect(cards.map((c) => c.id)).toEqual(["c1", "c2", "k1", "t1"]);
    expect(cards.map((c) => c.service)).toEqual(["CUP", "CUP", "CLASICA", "TROPICAL"]);
  });

  it("normalizes a CUP card: daily period, USDT paid derived from the rate", () => {
    const [card] = unifyCards([cupCard()], []);
    expect(card).toMatchObject({ key: "CUP:cup-1", unit: "CUP", period: "day", balance: 240000, limit: 120000, used: 30000, remaining: 90000 });
    expect(card.lots[0]).toMatchObject({ amount: 240000, remaining: 240000, usdtPaid: 250, rateCupPerUsdt: 960, usdPerUsdt: null, editable: true });
    expect(card.movements[0]).toMatchObject({ amount: 30000, customerName: "Ana", kind: "operacion" });
  });

  it("normalizes a USD card: monthly period, lot rate from usdPerUsdt", () => {
    const [card] = unifyCards([], [usdCard()]);
    expect(card).toMatchObject({ key: "CLASICA:usd-1", unit: "USD", period: "month", balance: 400, limit: 5000, used: 100, remaining: 4900 });
    expect(card.lots[0]).toMatchObject({ usdtPaid: 476.19, usdPerUsdt: 1.05, rateCupPerUsdt: null });
  });
});

describe("serviceTotals", () => {
  it("always returns the three services; sums active balances; flags empty ones", () => {
    const cards = unifyCards(
      [cupCard({ balanceCup: 100 }), cupCard({ id: "c2", balanceCup: 50 }), cupCard({ id: "c3", balanceCup: 999, active: false })],
      [usdCard({ balanceUsd: 0 })],
    );
    expect(serviceTotals(cards)).toEqual([
      { service: "CUP", unit: "CUP", cards: 2, balance: 150, empty: false },
      { service: "CLASICA", unit: "USD", cards: 1, balance: 0, empty: true },
      { service: "TROPICAL", unit: "USD", cards: 0, balance: 0, empty: true },
    ]);
  });
});

describe("filterCards / limitPercent", () => {
  it("filters by service; all keeps everything", () => {
    const cards = unifyCards([cupCard()], [usdCard(), usdCard({ id: "t", service: "TROPICAL" })]);
    expect(filterCards(cards, "all")).toHaveLength(3);
    expect(filterCards(cards, "TROPICAL").map((c) => c.id)).toEqual(["t"]);
  });
  it("percent of the limit used, clamped to 0..100", () => {
    const [cup, usd] = unifyCards([cupCard()], [usdCard({ usedThisMonthUsd: 9000 })]);
    expect(limitPercent(cup)).toBe(25);
    expect(limitPercent(usd)).toBe(100);
    expect(limitPercent({ ...cup, limit: 0 })).toBe(0);
  });
});

describe("costPerUsd / profitPerUsd", () => {
  it("cost = usdt_buy_gyd / usd_per_usdt; 238 at 5% = 226.67", () => {
    expect(costPerUsd(238, 1.05)).toBeCloseTo(226.67, 2);
    expect(costPerUsd(238, 1)).toBe(238);
  });
  it("profit = sell - cost; null without data", () => {
    expect(profitPerUsd(260, 226.67)).toBeCloseTo(33.33, 2);
    expect(costPerUsd(null, 1.05)).toBeNull();
    expect(costPerUsd(238, null)).toBeNull();
    expect(profitPerUsd(null, 226)).toBeNull();
  });
});
