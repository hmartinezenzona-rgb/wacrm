import { describe, expect, it } from "vitest";
import { mapUsdBalanceResult, mapUsdCardRecord, mapUsdLotRecord, mapUsdReport } from "./read-model";

const REPORT = {
  cuba_month: "2026-11-01",
  cards: [
    {
      id: "c1", service: "CLASICA", name: "Clásica A", last4: "1234", priority: 1, active: true,
      monthly_limit_usd: "5000", balance_usd: "400", used_this_month_usd: "100", remaining_month_usd: "4900",
      lots: [
        { id: "l1", amount_usd: "500", remaining_usd: "400", usdt_paid: "476.19", usd_per_usdt: "1.05", loaded_at: "2026-11-02T10:00:00Z", note: null, editable: false, agotado: false, adjusted: true, adjustment_net_usd: "5" },
        { id: "l2", amount_usd: "100", remaining_usd: "0", usdt_paid: "100", usd_per_usdt: "1", loaded_at: "2026-11-03T10:00:00Z", note: "x", editable: false, agotado: true, adjusted: false, adjustment_net_usd: null },
      ],
      consumptions_month: [
        { id: "k1", consumed_at: "2026-11-04T10:00:00Z", amount_usd: "100", lot_id: "l1", lot_usd_per_usdt: "1.05", operation_id: "op1", entry_id: "e1", source: "completed_operation", customer_name: "Ana", kind: "operacion", reason: null },
        { id: "k2", consumed_at: "2026-11-04T11:00:00Z", amount_usd: "-5", lot_id: "l1", lot_usd_per_usdt: "1.05", kind: "ajuste", reason: "fix" },
      ],
    },
  ],
  totals: {
    CLASICA: { cards: 1, balance_usd: "400", monthly_limit_usd: "5000", used_this_month_usd: "100", remaining_month_usd: "4900" },
    TROPICAL: { cards: 0, balance_usd: 0, monthly_limit_usd: 0, used_this_month_usd: 0, remaining_month_usd: 0 },
  },
};

describe("mapUsdReport", () => {
  it("maps cards, lots, consumptions and numeric strings", () => {
    const report = mapUsdReport(REPORT);
    expect(report.cubaMonth).toBe("2026-11-01");
    const card = report.cards[0];
    expect(card).toMatchObject({ id: "c1", service: "CLASICA", last4: "1234", monthlyLimitUsd: 5000, balanceUsd: 400, usedThisMonthUsd: 100, remainingMonthUsd: 4900, active: true });
    expect(card.lots[0]).toMatchObject({ amountUsd: 500, remainingUsd: 400, usdtPaid: 476.19, usdPerUsdt: 1.05, editable: false, exhausted: false, adjusted: true, adjustmentNetUsd: 5 });
    expect(card.lots[1]).toMatchObject({ exhausted: true, note: "x", adjustmentNetUsd: 0 });
    expect(card.consumptionsMonth[0]).toMatchObject({ amountUsd: 100, lotUsdPerUsdt: 1.05, operationId: "op1", customerName: "Ana", kind: "operacion" });
    expect(card.consumptionsMonth[1]).toMatchObject({ amountUsd: -5, kind: "ajuste", reason: "fix", operationId: null });
  });

  it("maps totals for both services", () => {
    const report = mapUsdReport(REPORT);
    expect(report.totals.CLASICA).toEqual({ cards: 1, balanceUsd: 400, monthlyLimitUsd: 5000, usedThisMonthUsd: 100, remainingMonthUsd: 4900 });
    expect(report.totals.TROPICAL.cards).toBe(0);
  });

  it("is empty-safe", () => {
    const report = mapUsdReport(null);
    expect(report.cards).toEqual([]);
    expect(report.cubaMonth).toBeNull();
    expect(report.totals.CLASICA.balanceUsd).toBe(0);
    expect(report.totals.TROPICAL.cards).toBe(0);
  });

  it("drops cards whose service is unknown", () => {
    expect(mapUsdReport({ cards: [{ id: "x", service: "OTRO", name: "n" }] }).cards).toEqual([]);
  });
});

describe("records", () => {
  it("maps a usd_cards row", () => {
    expect(mapUsdCardRecord({ id: "c1", service: "TROPICAL", name: "T", last4: null, priority: 2, monthly_limit_usd: "5000", active: false })).toEqual({
      id: "c1", service: "TROPICAL", name: "T", last4: null, priority: 2, monthlyLimitUsd: 5000, active: false,
    });
  });
  it("maps a usd_lots row", () => {
    expect(mapUsdLotRecord({ id: "l1", card_id: "c1", amount_usd: "500", remaining_usd: "500", usdt_paid: "476.19", usd_per_usdt: "1.05", loaded_at: "2026-11-02T10:00:00Z", note: null })).toEqual({
      id: "l1", cardId: "c1", amountUsd: 500, remainingUsd: 500, usdtPaid: 476.19, usdPerUsdt: 1.05, loadedAt: "2026-11-02T10:00:00Z", note: null,
    });
  });
  it("maps a balance adjustment", () => {
    expect(mapUsdBalanceResult({ card_id: "c1", saldo_anterior: "400", saldo_nuevo: "395", movimientos: [{ lot_id: "l1", amount_usd: "5" }] })).toEqual({
      cardId: "c1", previousBalanceUsd: 400, newBalanceUsd: 395, movements: [{ lotId: "l1", amountUsd: 5 }],
    });
  });
});
