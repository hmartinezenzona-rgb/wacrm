import { describe, expect, it } from "vitest";
import { formatNumber } from "./format-number";
import { moneyCellProps, moneyStripeClass, moneyTextClass, profitTone, signedMoney, totalTone } from "./money-tone";

const fmt = (n: number) => formatNumber(n, { minimumFractionDigits: 2, maximumFractionDigits: 2 });

describe("profitTone", () => {
  it("is profit above zero, loss below zero", () => {
    expect(profitTone(4000)).toBe("profit");
    expect(profitTone(-0.5)).toBe("loss");
  });

  it("is neutral for zero, a missing figure, or an amount that rounds to zero cents", () => {
    expect(profitTone(0)).toBe("neutral");
    expect(profitTone(null)).toBe("neutral");
    expect(profitTone(undefined)).toBe("neutral");
    expect(profitTone(0.004)).toBe("neutral");
    expect(profitTone(-0.004)).toBe("neutral");
  });
});

describe("signedMoney", () => {
  it("prefixes + to a positive figure", () => {
    expect(signedMoney(1157712.4, fmt)).toBe("+1 157 712,40");
  });

  it("prefixes the true minus sign U+2212 to a negative figure and formats its magnitude", () => {
    expect(signedMoney(-2500, fmt)).toBe("−2 500,00");
  });

  it("leaves zero, and anything that rounds to zero cents, unsigned", () => {
    expect(signedMoney(0, fmt)).toBe("0,00");
    expect(signedMoney(0.004, fmt)).toBe("0,00");
    expect(signedMoney(-0.004, fmt)).toBe("0,00");
  });
});

describe("tone class maps", () => {
  it("map every tone to a token-based class and neutral to nothing", () => {
    expect(moneyTextClass.profit).toBe("text-money-profit");
    expect(moneyTextClass.loss).toBe("text-money-loss");
    expect(moneyTextClass.out).toBe("text-money-out");
    expect(moneyTextClass.in).toBe("text-money-in");
    expect(moneyTextClass.neutral).toBe("");
    expect(moneyStripeClass.neutral).toBe("");
    expect(moneyStripeClass.profit).toContain("--money-profit");
    expect(moneyStripeClass.in).toContain("--money-in");
  });
});

describe("totalTone", () => {
  it("keeps facturado blue and invertido amber whatever the amount, and colours the result by its sign", () => {
    expect(totalTone("in", 0)).toBe("in");
    expect(totalTone("out", 500)).toBe("out");
    expect(totalTone("result", 500)).toBe("profit");
    expect(totalTone("result", -500)).toBe("loss");
    expect(totalTone("result", 0)).toBe("neutral");
  });
});

describe("moneyCellProps", () => {
  it("adds nothing for a neutral cell and the tone plus its class otherwise", () => {
    expect(moneyCellProps("neutral")).toEqual({});
    expect(moneyCellProps("in")).toEqual({ "data-tone": "in", className: "text-money-in" });
  });

  it("keeps the cell's own classes", () => {
    expect(moneyCellProps("neutral", "py-1 text-right")).toEqual({ className: "py-1 text-right" });
    expect(moneyCellProps("loss", "py-1")).toEqual({ "data-tone": "loss", className: "py-1 text-money-loss" });
  });
});
