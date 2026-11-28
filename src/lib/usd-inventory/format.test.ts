import { describe, expect, it } from "vitest";
import { discountLabel, discountToUsdtPaid, formatUsd, parsePercent, usdPerUsdtFromDiscount } from "./format";

describe("formatUsd", () => {
  it("groups thousands and drops empty decimals", () => {
    expect(formatUsd(5000)).toMatch(/^5\D?000$/);
    expect(formatUsd(476.19)).toMatch(/476[.,]19/);
  });
});

describe("discountLabel", () => {
  it.each([
    [1.05, "5%"],
    [1.0, "1x1"],
    [1.0000001, "1x1"],
    [500 / 476.19, "5%"],
    [1.025, "2.5%"],
    [0.98, "-2%"],
  ])("usd_per_usdt %s -> %s", (rate, label) => {
    expect(discountLabel(rate)).toBe(label);
  });
});

describe("parsePercent", () => {
  it.each([
    ["5", 5],
    ["5%", 5],
    [" 5,5 % ", 5.5],
    ["0", 0],
    ["1x1", 0],
    ["1X1", 0],
  ])("%j -> %s", (text, value) => {
    expect(parsePercent(text)).toBe(value);
  });
  it.each([["abc"], ["-3"], ["100"], ["150"], [""]])("%j -> null", (text) => {
    expect(parsePercent(text)).toBeNull();
  });
});

describe("discountToUsdtPaid", () => {
  it("500 USD at 5% -> 476.19 USDT", () => expect(discountToUsdtPaid(500, 5)).toBe(476.19));
  it("1x1 -> same amount", () => expect(discountToUsdtPaid(500, 0)).toBe(500));
  it("rounds to two decimals", () => expect(discountToUsdtPaid(100, 3)).toBe(97.09));
});

describe("usdPerUsdtFromDiscount", () => {
  it("5% -> 1.05", () => expect(usdPerUsdtFromDiscount(5)).toBeCloseTo(1.05, 10));
});
