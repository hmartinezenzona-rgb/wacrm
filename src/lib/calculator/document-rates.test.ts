import { describe, expect, it } from "vitest";
import { CalculatorValidationError } from "./errors";
import {
  computeAutoCompletionSnapshot,
  computeAutoCompletionSnapshotFromDeposit,
  deriveAmountFromDeposit,
  missingDocumentRates,
  rateInputForService,
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
  it("rounds a 24000 GYD deposit at 260 up to 93 ZELLE and calculates from that amount", () => {
    const result = computeAutoCompletionSnapshotFromDeposit("ZELLE", 24_000, doc());
    expect(result?.amount).toBe(93);
    expect(result?.financials).toEqual({
      facturadoGyd: 24_180,
      invertidoGyd: 22_320,
      retornoGyd: 1_860,
    });
  });

  it.each(["CLASICA", "TROPICAL"] as const)(
    "uses the same deposit-to-whole-unit rule for %s",
    (service) => {
      expect(deriveAmountFromDeposit(service, 24_000, doc())).toBe(93);
    },
  );

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
