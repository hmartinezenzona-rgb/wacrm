import { describe, expect, it } from "vitest";
import type { CloseEntry } from "@/lib/financial-close/read-model";
import { rateLabel } from "./financial-close-format";

function entry(overrides: Partial<CloseEntry>): CloseEntry {
  return {
    id: "e1",
    operationId: "op-1",
    source: "completed_operation",
    day: "2026-10-03",
    completedAt: null,
    customerName: "Bruce",
    service: "ZELLE",
    amount: 100,
    amountCurrency: "USD",
    cupRate: null,
    cupGlobalRate: null,
    usdtBuyGyd: 240,
    usdtSellGyd: 260,
    rateVersionId: null,
    facturadoGyd: null,
    invertidoGyd: null,
    retornoGyd: null,
    deliveryMode: null,
    actorUserId: null,
    actorName: null,
    ...overrides,
  };
}

describe("rateLabel", () => {
  it("keeps the USDT buy/sell label for the Zelle family", () => {
    expect(rateLabel(entry({}))).toBe("USDT 240/260");
  });

  it("labels a CUP entry by its CUP rate", () => {
    expect(rateLabel(entry({ service: "CUP", cupRate: 975 }))).toBe("CUP 975");
  });

  it("reads the cash sale rate (snapshotted in usdtSellGyd) for an EFECTIVO entry", () => {
    expect(rateLabel(entry({ service: "EFECTIVO", usdtSellGyd: 290 }))).toBe("EFECTIVO 240/290");
  });
});
