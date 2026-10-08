import { describe, expect, it } from "vitest";
import { formatNumber, formatNumberParts, localizeSeparators } from "./format-number";

const NNBSP = " ";

describe("formatNumber", () => {
  it("groups in threes with a narrow no-break space and uses a comma for the decimal", () => {
    expect(formatNumber(1157712.4, { minimumFractionDigits: 2, maximumFractionDigits: 2 })).toBe(`1${NNBSP}157${NNBSP}712,40`);
  });

  it("groups four-digit numbers too", () => {
    expect(formatNumber(5000)).toBe(`5${NNBSP}000`);
    expect(formatNumber(1234.5, { maximumFractionDigits: 2 })).toBe(`1${NNBSP}234,5`);
  });

  it("leaves short numbers alone", () => {
    expect(formatNumber(0)).toBe("0");
    expect(formatNumber(999)).toBe("999");
  });

  it("keeps the negative sign and the requested precision", () => {
    expect(formatNumber(-1234567.891, { maximumFractionDigits: 2 })).toBe(`-1${NNBSP}234${NNBSP}567,89`);
    expect(formatNumber(12, { minimumFractionDigits: 2, maximumFractionDigits: 2 })).toBe("12,00");
  });

  it("does not round away digits when no precision is given beyond the integer default", () => {
    expect(formatNumber(1234.567)).toBe(`1${NNBSP}234,567`);
  });
});

describe("localizeSeparators", () => {
  it("swaps the en-US separators of an already formatted string", () => {
    expect(localizeSeparators("$1,618,310.5")).toBe(`$1${NNBSP}618${NNBSP}310,5`);
  });
});

describe("formatNumberParts", () => {
  it("localizes only the group and decimal parts of a currency-styled formatter", () => {
    const fmt = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
    expect(formatNumberParts(fmt, 1234567.5)).toBe(`$1${NNBSP}234${NNBSP}567,50`);
  });
});
