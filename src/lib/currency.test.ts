import { describe, expect, it } from "vitest";
import {
  CURRENCIES,
  DEFAULT_CURRENCY,
  formatCurrency,
  formatCurrencyShort,
} from "./currency";

describe("formatCurrency", () => {
  it("formats whole amounts with no minor units", () => {
    // Use a non-breaking-space-tolerant check: Intl may insert NBSP.
    const out = formatCurrency(1234, "USD");
    expect(out).toContain("1,234");
    expect(out).not.toContain(".00");
  });

  it("defaults to USD when no currency is given", () => {
    expect(formatCurrency(10)).toBe(formatCurrency(10, DEFAULT_CURRENCY));
  });

  it("treats an empty-string currency as the default", () => {
    expect(formatCurrency(10, "")).toBe(formatCurrency(10, DEFAULT_CURRENCY));
  });

  it("coerces non-finite values to 0", () => {
    expect(formatCurrency(Number.NaN, "USD")).toContain("0");
  });

  it("renders a well-formed but unknown ISO code without throwing", () => {
    // Intl is lenient here — it uses the code as the symbol.
    const out = formatCurrency(1234, "ZZZ");
    expect(out).toContain("ZZZ");
    expect(out).toContain("1,234");
  });

  it("never throws on a structurally invalid code (no DB CHECK on deals.currency)", () => {
    for (const bad of ["United States", "US", "USDD", "12", "u$d"]) {
      expect(() => formatCurrency(1234, bad)).not.toThrow();
      expect(formatCurrency(1234, bad)).toContain("1,234");
    }
  });

  it("formats every offered currency without throwing", () => {
    for (const c of CURRENCIES) {
      expect(() => formatCurrency(1000, c.code)).not.toThrow();
    }
  });
});

describe("formatCurrencyShort", () => {
  it("abbreviates millions and thousands with the currency symbol", () => {
    expect(formatCurrencyShort(2_500_000, "USD")).toBe("$2.5M");
    expect(formatCurrencyShort(3_400, "USD")).toBe("$3.4k");
    expect(formatCurrencyShort(900, "USD")).toBe("$900");
  });

  it("uses the matching symbol for non-USD currencies", () => {
    expect(formatCurrencyShort(1_000, "EUR")).toBe("€1.0k");
    expect(formatCurrencyShort(1_000, "INR")).toBe("₹1.0k");
  });

  it("falls back to the code prefix for unknown currencies (no throw)", () => {
    expect(formatCurrencyShort(1_000, "ZZZ")).toBe("ZZZ 1.0k");
  });
});

describe("formatCurrency locale stability", () => {
  // The formatters used to pass `undefined` as the locale, so the same
  // amount rendered differently per viewer. These pin the contract.
  it("renders USD with the symbol, not the browser's guess", () => {
    expect(formatCurrency(1_618_310, "USD")).toBe("$1,618,310");
  });

  it("keeps the code for currencies that have no symbol anywhere", () => {
    // GYD and CUP are the two this business actually moves. Intl puts a
    // non-breaking space between code and number, so normalise it — the
    // same tolerance the suite above already applies.
    const flat = (s: string) => s.replace(/\u00a0/g, " ");
    expect(flat(formatCurrency(25_000, "GYD"))).toBe("GYD 25,000");
    expect(flat(formatCurrency(1_200, "CUP"))).toBe("CUP 1,200");
  });

  it("groups with commas regardless of the machine's locale", () => {
    expect(formatCurrency(1_000_000, "EUR")).toBe("\u20ac1,000,000");
  });
});

describe("the currencies this business actually moves", () => {
  // Remesas Core's `Currency` enum is GYD / CUP / USD. GYD and CUP were
  // missing from the picker, so the account could not be set to them —
  // which is why pipeline columns summed GYD deals under a USD label.
  it("offers GYD and CUP", () => {
    const codes = CURRENCIES.map((c) => c.code);
    expect(codes).toContain("GYD");
    expect(codes).toContain("CUP");
  });

  it("lists them before the rest, since they are the default case here", () => {
    expect(CURRENCIES.slice(0, 3).map((c) => c.code)).toEqual([
      "GYD",
      "CUP",
      "USD",
    ]);
  });

  it("marks them with their code, never an invented dollar sign", () => {
    // A "$" on CUP would read as US dollars on a board that carries both.
    expect(formatCurrencyShort(25_000, "GYD")).toBe("GYD 25.0k");
    expect(formatCurrencyShort(1_200_000, "CUP")).toBe("CUP 1.2M");
  });

  it("every code still satisfies the accounts.default_currency CHECK", () => {
    // The column is constrained to `^[A-Z]{3}$`, so anything that is not
    // a three-letter ISO code cannot be an account default at all.
    for (const c of CURRENCIES) expect(c.code).toMatch(/^[A-Z]{3}$/);
  });
});
