import { describe, expect, it } from "vitest";
import { CalculatorValidationError } from "./errors";
import {
  computeAutoCompletionSnapshot,
  computeAutoCompletionSnapshotFromDeposit,
  deriveAmountFromDeposit,
  missingDocumentRates,
  rateInputForService,
  zelleQuoteFromDeposit,
  zelleRateForUsd,
  zelleTiers,
  type CalculatorDocumentRates,
} from "./document-rates";

function doc(overrides: Partial<CalculatorDocumentRates> = {}): CalculatorDocumentRates {
  return {
    cupGlobalRate: 3,
    usdtBuyGyd: 240,
    usdtSellGyd: 260,
    usdtSellCup: 975,
    ...overrides,
  };
}

describe("missingDocumentRates", () => {
  it("CUP requires cupGlobalRate, usdtSellCup and usdtBuyGyd", () => {
    expect(missingDocumentRates("CUP", doc())).toEqual([]);
    expect(missingDocumentRates("CUP", doc({ usdtSellCup: null }))).toEqual(["usdtSellCup"]);
    expect(missingDocumentRates("CUP", doc({ usdtBuyGyd: null, usdtSellCup: null }))).toEqual([
      "usdtSellCup",
      "usdtBuyGyd",
    ]);
  });

  // Design decision 9: cupGlobalRate is no longer NOT NULL / defaulted at
  // the DB layer — a missing global rate must surface exactly like any
  // other missing required rate, never default to 3.
  it("CUP also reports cupGlobalRate as missing when it is null (no default of 3)", () => {
    expect(missingDocumentRates("CUP", doc({ cupGlobalRate: null }))).toEqual(["cupGlobalRate"]);
  });

  it.each(["ZELLE", "CLASICA", "TROPICAL", "USDT"] as const)(
    "%s requires usdtBuyGyd and usdtSellGyd only",
    (service) => {
      expect(missingDocumentRates(service, doc())).toEqual([]);
      expect(missingDocumentRates(service, doc({ usdtSellGyd: null }))).toEqual(["usdtSellGyd"]);
      // cupGlobalRate/usdtSellCup are irrelevant to this family.
      expect(missingDocumentRates(service, doc({ usdtSellCup: null }))).toEqual([]);
    },
  );
});

describe("rateInputForService", () => {
  it("maps CUP's global rates onto costGyd/cupRate/cupGlobalRate", () => {
    expect(rateInputForService("CUP", doc())).toEqual({
      costGyd: 240,
      cupRate: 975,
      cupGlobalRate: 3,
    });
  });

  it("maps a null cupGlobalRate to undefined instead of passing null through", () => {
    expect(rateInputForService("CUP", doc({ cupGlobalRate: null }))).toEqual({
      costGyd: 240,
      cupRate: 975,
      cupGlobalRate: undefined,
    });
  });

  it("maps ZELLE-family global rates onto costGyd/saleGyd", () => {
    expect(rateInputForService("ZELLE", doc())).toEqual({ costGyd: 240, saleGyd: 260 });
    expect(rateInputForService("CLASICA", doc())).toEqual({ costGyd: 240, saleGyd: 260 });
    expect(rateInputForService("TROPICAL", doc())).toEqual({ costGyd: 240, saleGyd: 260 });
    expect(rateInputForService("USDT", doc())).toEqual({ costGyd: 240, saleGyd: 260 });
  });
});

describe("computeAutoCompletionSnapshot", () => {
  // Acceptance criterion B: ZELLE 100 with buy=240/sell=260.
  it("ZELLE 100 with 240/260 -> facturado 26000, invertido 24000, retorno 2000", () => {
    const result = computeAutoCompletionSnapshot("ZELLE", 100, doc());
    expect(result.facturadoGyd).toBeCloseTo(26_000, 6);
    expect(result.invertidoGyd).toBeCloseTo(24_000, 6);
    expect(result.retornoGyd).toBeCloseTo(2_000, 6);
  });

  // Acceptance criterion C: CUP 30000 with cup_global=3, buy=240, sell_cup=975.
  it("CUP 30000 with cup_global=3, buy=240, sell_cup=975 -> facturado 10000, invertido 7384.615..., retorno 2615.384...", () => {
    const result = computeAutoCompletionSnapshot("CUP", 30_000, doc());
    expect(result.facturadoGyd).toBeCloseTo(10_000, 6);
    expect(result.invertidoGyd).toBeCloseTo(7_384.615384615385, 6);
    expect(result.retornoGyd).toBeCloseTo(2_615.384615384615, 6);
  });

  // Acceptance criterion D: USDT explicit uses the same buy/sell GYD rates,
  // no discount — same shape as ZELLE.
  it("USDT 1000 with buy=240/sell=260 -> facturado 260000, invertido 240000, retorno 20000", () => {
    const result = computeAutoCompletionSnapshot("USDT", 1_000, doc());
    expect(result.facturadoGyd).toBeCloseTo(260_000, 6);
    expect(result.invertidoGyd).toBeCloseTo(240_000, 6);
    expect(result.retornoGyd).toBeCloseTo(20_000, 6);
  });

  it.each(["CLASICA", "TROPICAL"] as const)(
    "%s uses the same no-discount formula as ZELLE",
    (service) => {
      const result = computeAutoCompletionSnapshot(service, 100, doc());
      expect(result.facturadoGyd).toBeCloseTo(26_000, 6);
      expect(result.invertidoGyd).toBeCloseTo(24_000, 6);
    },
  );

  // Design decision 10 / spec "Global Rate Snapshot at Delivery": a missing
  // required rate MUST raise a validation error naming the missing rate,
  // and MUST NOT compute the entry using zero/a default for that rate.
  it("throws CalculatorValidationError naming the missing rate instead of computing with zero (CUP)", () => {
    expect(() => computeAutoCompletionSnapshot("CUP", 30_000, doc({ usdtSellCup: null }))).toThrow(
      CalculatorValidationError,
    );
    expect(() => computeAutoCompletionSnapshot("CUP", 30_000, doc({ usdtBuyGyd: null }))).toThrow(
      CalculatorValidationError,
    );
  });

  it("throws CalculatorValidationError naming cupGlobalRate when it is null (never defaults to 3)", () => {
    expect(() =>
      computeAutoCompletionSnapshot("CUP", 30_000, doc({ cupGlobalRate: null })),
    ).toThrow(CalculatorValidationError);
    try {
      computeAutoCompletionSnapshot("CUP", 30_000, doc({ cupGlobalRate: null }));
      throw new Error("expected computeAutoCompletionSnapshot to throw");
    } catch (error) {
      expect(error).toBeInstanceOf(CalculatorValidationError);
      expect((error as CalculatorValidationError).field).toBe("cupGlobalRate");
    }
  });

  it("throws CalculatorValidationError naming the missing rate instead of computing with zero (ZELLE)", () => {
    expect(() => computeAutoCompletionSnapshot("ZELLE", 100, doc({ usdtSellGyd: null }))).toThrow(
      CalculatorValidationError,
    );
    expect(() => computeAutoCompletionSnapshot("ZELLE", 100, doc({ usdtBuyGyd: null }))).toThrow(
      CalculatorValidationError,
    );
  });

  it("never falls back to a silent commercial default (e.g. 240/260/975) when rates are absent", () => {
    const emptyDoc = doc({ cupGlobalRate: null, usdtBuyGyd: null, usdtSellGyd: null, usdtSellCup: null });
    expect(() => computeAutoCompletionSnapshot("CUP", 30_000, emptyDoc)).toThrow(
      CalculatorValidationError,
    );
    expect(() => computeAutoCompletionSnapshot("ZELLE", 100, emptyDoc)).toThrow(
      CalculatorValidationError,
    );
    expect(() => computeAutoCompletionSnapshot("USDT", 1_000, emptyDoc)).toThrow(
      CalculatorValidationError,
    );
  });
});

describe("deposit-based automatic calculation", () => {
  it("rounds a 24000 GYD deposit at 260 down to 92 ZELLE and calculates from that amount", () => {
    const result = computeAutoCompletionSnapshotFromDeposit("ZELLE", 24_000, doc());
    expect(result?.amount).toBe(92);
    expect(result?.financials).toEqual({
      facturadoGyd: 23_920,
      invertidoGyd: 22_080,
      retornoGyd: 1_840,
    });
  });

  it.each(["CLASICA", "TROPICAL"] as const)(
    "uses the same deposit-to-whole-unit rule for %s",
    (service) => {
      expect(deriveAmountFromDeposit(service, 24_000, doc())).toBe(92);
    },
  );

  // Pinned business case (owner-confirmed): 75,000 GYD at 260 GYD/USD is
  // 288.46 USD. Delivering 289 would hand over 289 x 260 = 75,140 GYD of
  // value against a 75,000 GYD deposit -- 140 GYD out of the business's
  // pocket on every remittance. The rounding must favour the business:
  // floor, never ceil.
  it("floors 75000 GYD at rate 260 to 288, not 289 (owner-confirmed business case)", () => {
    expect(deriveAmountFromDeposit("ZELLE", 75_000, doc({ usdtSellGyd: 260 }))).toBe(288);
  });

  it("converts a GYD deposit to CUP before applying the CUP formula", () => {
    const result = computeAutoCompletionSnapshotFromDeposit("CUP", 5_000, doc());
    expect(result?.amount).toBe(15_000);
    expect(result?.financials.facturadoGyd).toBe(5_000);
    expect(result?.financials.invertidoGyd).toBeCloseTo(3_692.3076923076924, 10);
    expect(result?.financials.retornoGyd).toBeCloseTo(1_307.6923076923076, 10);
  });

  it("returns null when the deposit amount itself is invalid (not a rate problem)", () => {
    expect(computeAutoCompletionSnapshotFromDeposit("ZELLE", 0, doc())).toBeNull();
    expect(deriveAmountFromDeposit("ZELLE", -1, doc())).toBeNull();
    expect(deriveAmountFromDeposit("ZELLE", Number.NaN, doc())).toBeNull();
  });

  // Design decision 10: a missing conversion rate needed to derive the
  // amount from the deposit is a validation error, not a silent null —
  // the caller must not compute the entry from a guessed unit count.
  it("throws CalculatorValidationError naming the missing rate when the deposit basis rate is unavailable", () => {
    expect(() => deriveAmountFromDeposit("ZELLE", 24_000, doc({ usdtSellGyd: null }))).toThrow(
      CalculatorValidationError,
    );
    expect(() => deriveAmountFromDeposit("CUP", 5_000, doc({ cupGlobalRate: null }))).toThrow(
      CalculatorValidationError,
    );
  });
});

describe("EFECTIVO (cash dollars) — migration 193", () => {
  const cash = (overrides: Partial<CalculatorDocumentRates> = {}) => doc({ efectivoUsdGyd: 290, ...overrides });

  it("requires the shared buy rate and the cash sale rate, not usdtSellGyd", () => {
    expect(missingDocumentRates("EFECTIVO", cash())).toEqual([]);
    expect(missingDocumentRates("EFECTIVO", cash({ usdtSellGyd: null }))).toEqual([]);
    expect(missingDocumentRates("EFECTIVO", doc())).toEqual(["efectivoUsdGyd"]);
    expect(missingDocumentRates("EFECTIVO", cash({ usdtBuyGyd: null, efectivoUsdGyd: null }))).toEqual([
      "usdtBuyGyd",
      "efectivoUsdGyd",
    ]);
  });

  it("sells at the cash rate and costs the shared buy rate", () => {
    expect(rateInputForService("EFECTIVO", cash())).toEqual({ costGyd: 240, saleGyd: 290 });
  });

  it("derives whole USD from the GYD deposit at the cash rate (floor)", () => {
    expect(deriveAmountFromDeposit("EFECTIVO", 29_000, cash())).toBe(100);
    expect(deriveAmountFromDeposit("EFECTIVO", 29_289, cash())).toBe(100);
  });

  it("names efectivoUsdGyd when the cash rate is missing", () => {
    expect(() => deriveAmountFromDeposit("EFECTIVO", 29_000, doc())).toThrow(/efectivoUsdGyd/);
  });

  it("prices 29,000 GYD at 290/240 as 100 USD, facturado 29,000, invertido 24,000, retorno 5,000", () => {
    expect(computeAutoCompletionSnapshotFromDeposit("EFECTIVO", 29_000, cash())).toEqual({
      amount: 100,
      financials: { facturadoGyd: 29_000, invertidoGyd: 24_000, retornoGyd: 5_000 },
    });
  });
});

// Migration 216: Zelle is priced by tier of USD received. The minimums are fixed (50, 1,000, 2,000 USD); the three prices
// come from the rate version (zelleSellGyd, zelleSellGyd1000, zelleSellGyd2000). A missing price falls back: base tier ->
// usdtSellGyd, 1,000 tier -> base price, 2,000 tier -> 1,000 price. Mirrors cerebro_zelle_cotizar_gyd / cerebro_tasa_zelle.
describe("ZELLE tiers — migration 216", () => {
  const tiers = { zelleSellGyd: 260, zelleSellGyd1000: 250, zelleSellGyd2000: 245 };

  it("250,000 GYD reaches the 1,000 USD tier: 1,000 USD at 250", () => {
    expect(deriveAmountFromDeposit("ZELLE", 250_000, doc(tiers))).toBe(1_000);
    expect(zelleQuoteFromDeposit(250_000, doc(tiers))).toEqual({ usd: 1_000, rate: 250 });
  });

  it("249,999 GYD stays on the base tier: 961 USD at 260", () => {
    expect(deriveAmountFromDeposit("ZELLE", 249_999, doc(tiers))).toBe(961);
    expect(zelleQuoteFromDeposit(249_999, doc(tiers))).toEqual({ usd: 961, rate: 260 });
  });

  it("490,000 GYD reaches the 2,000 USD tier: 2,000 USD at 245; 489,999 stays at 250 (1,959 USD)", () => {
    expect(zelleQuoteFromDeposit(490_000, doc(tiers))).toEqual({ usd: 2_000, rate: 245 });
    expect(zelleQuoteFromDeposit(489_999, doc(tiers))).toEqual({ usd: 1_959, rate: 250 });
  });

  it("custom prices 265/255/250: 255,000 -> 1,000 at 255; 250,000 -> 943 at 265; 500,000 -> 2,000 at 250", () => {
    const custom = doc({ zelleSellGyd: 265, zelleSellGyd1000: 255, zelleSellGyd2000: 250 });
    expect(zelleQuoteFromDeposit(255_000, custom)).toEqual({ usd: 1_000, rate: 255 });
    expect(zelleQuoteFromDeposit(250_000, custom)).toEqual({ usd: 943, rate: 265 });
    expect(zelleQuoteFromDeposit(500_000, custom)).toEqual({ usd: 2_000, rate: 250 });
  });

  it("below the lowest tier the base price applies; a non-positive deposit has no quote", () => {
    expect(zelleQuoteFromDeposit(12_999, doc(tiers))).toEqual({ usd: 49, rate: 260 });
    expect(zelleQuoteFromDeposit(0, doc(tiers))).toBeNull();
  });

  it("rate for a USD amount: highest tier it reaches", () => {
    const d = doc(tiers);
    expect([49, 50, 999, 1_000, 1_999, 2_000, 5_000].map((usd) => zelleRateForUsd(usd, d))).toEqual([
      260, 260, 260, 250, 250, 245, 245,
    ]);
  });

  it("NULL prices fall back: base -> usdtSellGyd, 1,000 -> base, 2,000 -> 1,000", () => {
    expect(zelleTiers(doc({ usdtSellGyd: 262 }))).toEqual([
      { minUsd: 50, rateGyd: 262 },
      { minUsd: 1_000, rateGyd: 262 },
      { minUsd: 2_000, rateGyd: 262 },
    ]);
    expect(zelleTiers(doc({ usdtSellGyd: 262, zelleSellGyd1000: 255 }))).toEqual([
      { minUsd: 50, rateGyd: 262 },
      { minUsd: 1_000, rateGyd: 255 },
      { minUsd: 2_000, rateGyd: 255 },
    ]);
    expect(zelleTiers(doc({ zelleSellGyd: 265, zelleSellGyd1000: 255 }))).toEqual([
      { minUsd: 50, rateGyd: 265 },
      { minUsd: 1_000, rateGyd: 255 },
      { minUsd: 2_000, rateGyd: 255 },
    ]);
  });

  it("with no Zelle price at all, Zelle still prices at the single rate (no discount)", () => {
    expect(deriveAmountFromDeposit("ZELLE", 250_000, doc())).toBe(961);
  });

  it("the snapshot of a 250,000 GYD ZELLE deposit sells at 250: facturado 250,000, invertido 240,000, retorno 10,000", () => {
    const result = computeAutoCompletionSnapshotFromDeposit("ZELLE", 250_000, doc(tiers));
    expect(result?.amount).toBe(1_000);
    expect(result?.financials).toEqual({ facturadoGyd: 250_000, invertidoGyd: 240_000, retornoGyd: 10_000 });
  });

  it("rateInputForService prices a ZELLE amount by its tier; other services keep usdtSellGyd", () => {
    expect(rateInputForService("ZELLE", doc(tiers), 1_000)).toEqual({ costGyd: 240, saleGyd: 250 });
    expect(rateInputForService("ZELLE", doc(tiers), 2_500)).toEqual({ costGyd: 240, saleGyd: 245 });
    expect(rateInputForService("ZELLE", doc(tiers))).toEqual({ costGyd: 240, saleGyd: 260 });
    expect(rateInputForService("CLASICA", doc(tiers), 1_000)).toEqual({ costGyd: 240, saleGyd: 260 });
    expect(deriveAmountFromDeposit("CLASICA", 250_000, doc(tiers))).toBe(961);
  });
});
