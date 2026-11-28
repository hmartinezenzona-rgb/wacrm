import { describe, expect, it } from "vitest";
import type { CloseEntry } from "@/lib/financial-close/read-model";
import { fmtAmount, fmtGyd, rateLabel } from "./financial-close-format";

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

const N = "\u202f";

describe("fmtGyd / fmtAmount", () => {
  it("writes ledger money with spaced thousands and a decimal comma", () => {
    expect(fmtGyd(1157712.4)).toBe(`1${N}157${N}712,4 GYD`);
    expect(fmtGyd(5000)).toBe(`5${N}000 GYD`);
    expect(fmtGyd(null)).toBe("—");
    expect(fmtAmount(45000.256, "CUP")).toBe(`45${N}000,26 CUP`);
  });
});

describe("rateLabel figures", () => {
  it("groups a rate of four or more digits and uses the decimal comma", () => {
    expect(rateLabel(entry({ service: "CUP", cupRate: 1250.5 }))).toBe(`CUP 1${N}250,5`);
    expect(rateLabel(entry({ usdtBuyGyd: 240.5, usdtSellGyd: 260 }))).toBe("USDT 240,5/260");
  });
});
