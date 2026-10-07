import { describe, expect, it } from "vitest";
import type { CalculatorDocumentRates } from "@/lib/calculator/document-rates";
import { destinationCurrencyOf, previewDestinationAmount } from "./destination-quote";

const rates: CalculatorDocumentRates = {
  cupGlobalRate: 3.5,
  usdtBuyGyd: 250,
  usdtSellGyd: 260,
  usdtSellCup: 500,
  efectivoUsdGyd: 270,
  zelleSellGyd: 262,
  zelleSellGyd1000: 258,
  zelleSellGyd2000: 255,
};

describe("destinationCurrencyOf", () => {
  it("names the currency each rail delivers in", () => {
    expect(destinationCurrencyOf("cuban_card")).toBe("CUP");
    for (const s of ["zelle", "clasica", "tropical", "efectivo_usd"]) expect(destinationCurrencyOf(s)).toBe("USD");
  });

  it("is null for services without a destination quote and for no service", () => {
    for (const s of ["recarga", "saldo", "combo", "visa", ""]) expect(destinationCurrencyOf(s)).toBeNull();
  });
});

describe("previewDestinationAmount", () => {
  it("CUP rounds deposit x cup rate", () => {
    expect(previewDestinationAmount("cuban_card", 26001, rates)).toBe(91004); // 91003.5 -> 91004
  });

  it("clasica and tropical floor deposit / usd rate", () => {
    expect(previewDestinationAmount("clasica", 26000, rates)).toBe(100);
    expect(previewDestinationAmount("tropical", 26259, rates)).toBe(100);
  });

  it("zelle floors at the tier rate", () => {
    expect(previewDestinationAmount("zelle", 26200, rates)).toBe(100);
  });

  it("efectivo_usd floors at the cash rate", () => {
    expect(previewDestinationAmount("efectivo_usd", 27000, rates)).toBe(100);
  });

  it("is null without quote, rates, a positive deposit or the needed rate", () => {
    expect(previewDestinationAmount("recarga", 26000, rates)).toBeNull();
    expect(previewDestinationAmount("clasica", 26000, null)).toBeNull();
    expect(previewDestinationAmount("clasica", 0, rates)).toBeNull();
    expect(previewDestinationAmount("clasica", Number.NaN, rates)).toBeNull();
    expect(previewDestinationAmount("clasica", 26000, { ...rates, usdtSellGyd: null })).toBeNull();
  });
});
