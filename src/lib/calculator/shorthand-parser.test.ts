import { describe, expect, it } from "vitest";
import { normalizeManualEntry } from "./entries";
import { CalculatorValidationError } from "./errors";
import { parseMonto, parseShorthandLine } from "./shorthand-parser";

// Parsing semantics are ported from the reference `web-calculator.ts`
// (`parsearLinea`/`serviceFrom`/`parseMonto`), but every place the
// reference silently defaulted a missing/invalid numeric token to 0 (or
// fell through to "DESCONOCIDO" for an unrecognized service) now reports
// an explicit parse error instead of creating a bad entry.

describe("parseMonto", () => {
  it("multiplies a trailing k by 1000", () => {
    expect(parseMonto("30k")).toBe(30_000);
    expect(parseMonto("6.2k")).toBe(6_200);
  });

  it("strips a trailing gyd unit and thousands separators", () => {
    expect(parseMonto("4,081.64 usdt")).toBe(4_081.64);
    expect(parseMonto("1,000 gyd")).toBe(1_000);
  });

  it("returns null — never 0 — for a missing or non-numeric token", () => {
    expect(parseMonto(undefined)).toBeNull();
    expect(parseMonto("")).toBeNull();
    expect(parseMonto("abc")).toBeNull();
  });
});

describe("parseShorthandLine — bullet stripping and blank lines", () => {
  it("strips a leading bullet, dash or asterisk", () => {
    const bullet = parseShorthandLine("• Jaila 150 Zelle (240/260)", "General");
    const dash = parseShorthandLine("- Jaila 150 Zelle (240/260)", "General");
    const asterisk = parseShorthandLine("* Jaila 150 Zelle (240/260)", "General");
    for (const result of [bullet, dash, asterisk]) {
      expect(result).toMatchObject({ kind: "entry", draft: { customerName: "Jaila", service: "ZELLE" } });
    }
  });

  it("returns null for a blank line", () => {
    expect(parseShorthandLine("   ", "General")).toBeNull();
    expect(parseShorthandLine("", "General")).toBeNull();
  });
});

describe("parseShorthandLine — day headers", () => {
  it.each(["Lunes 7", "martes", "Miércoles", "jueves 10", "viernes", "sábado", "domingo"])(
    "recognizes %s as a day header",
    (line) => {
      const result = parseShorthandLine(line, "General");
      expect(result).toEqual({ kind: "day", day: line });
    },
  );
});

describe("parseShorthandLine — service abbreviations", () => {
  it("maps REC to RECARGA", () => {
    const result = parseShorthandLine("Onaisy 1 rec promo(23.1/6.2k/240)", "General");
    expect(result).toMatchObject({
      kind: "entry",
      draft: { service: "RECARGA", customerName: "Onaisy", amount: 1 },
    });
  });

  it("substitutes 6.2k with 6200 for the RECARGA saleGyd rate (spec scenario)", () => {
    const result = parseShorthandLine("• Onaisy 1 rec promo(23.1/6.2k/240)", "General");
    if (result?.kind !== "entry") throw new Error("expected entry");
    expect(result.draft.saleGyd).toBe(6_200);
    expect(result.draft.costGyd).toBe(23.1);
    expect(result.draft.cupRate).toBe(240);
  });

  it("maps saldo/movil to SALDO_MOVIL (underscore identifier)", () => {
    const result = parseShorthandLine("Carlos 2 saldo movil (1.25/1k/242.21)", "General");
    expect(result).toMatchObject({ kind: "entry", draft: { service: "SALDO_MOVIL" } });
  });

  it("maps clasica/clásica/tropical/usdt/mlc/cup", () => {
    expect(parseShorthandLine("Pedro 150 MLC (30%/240/245)", "General")).toMatchObject({
      draft: { service: "MLC" },
    });
    expect(parseShorthandLine("Pedro 150 Clasica (30%/240/245)", "General")).toMatchObject({
      draft: { service: "CLASICA" },
    });
    expect(parseShorthandLine("Pedro 150 Tropical (30%/240/245)", "General")).toMatchObject({
      draft: { service: "TROPICAL" },
    });
    expect(parseShorthandLine("Carlos 1k usdt (235/260)", "General")).toMatchObject({
      draft: { service: "USDT" },
    });
    expect(parseShorthandLine("Bladimir 30k CUP (240/975)", "General")).toMatchObject({
      draft: { service: "CUP" },
    });
  });
});

describe("parseShorthandLine — CUP (no default of 980 for a missing cupRate)", () => {
  it("parses costGyd and cupRate from the two-value detail", () => {
    const result = parseShorthandLine("Bladimir 30k CUP (240/975)", "General");
    if (result?.kind !== "entry") throw new Error("expected entry");
    expect(result.draft.costGyd).toBe(240);
    expect(result.draft.cupRate).toBe(975);
    // cupGlobalRate is a global input, never present in the per-line detail
    // — ShorthandEntryDraft has no such field, enforced at compile time.
    expect("cupGlobalRate" in result.draft).toBe(false);
  });

  it("leaves cupRate undefined (never defaulted to 980) when the detail omits it", () => {
    const result = parseShorthandLine("Bladimir 30k CUP (240)", "General");
    if (result?.kind !== "entry") throw new Error("expected entry");
    expect(result.draft.costGyd).toBe(240);
    expect(result.draft.cupRate).toBeUndefined();
  });
});

describe("parseShorthandLine — ZELLE/MLC/CLASICA/TROPICAL discount", () => {
  it("parses the optional leading percentage as discountPct (not divided by 100)", () => {
    const result = parseShorthandLine("Julié 2.8k Zelle (3%/235/250)", "General");
    if (result?.kind !== "entry") throw new Error("expected entry");
    expect(result.draft.discountPct).toBe(3);
    expect(result.draft.costGyd).toBe(235);
    expect(result.draft.saleGyd).toBe(250);
  });

  it("has no discountPct when the detail has no percentage", () => {
    const result = parseShorthandLine("Jaila 150 Zelle (240/260)", "General");
    if (result?.kind !== "entry") throw new Error("expected entry");
    expect(result.draft.discountPct).toBeUndefined();
    expect(result.draft.costGyd).toBe(240);
    expect(result.draft.saleGyd).toBe(260);
  });
});

describe("parseShorthandLine — direct services", () => {
  it("parses a direct-service line into service DIRECTO with a label", () => {
    const result = parseShorthandLine("Iza 1 ext visa 5k GYD", "General");
    expect(result).toMatchObject({
      kind: "entry",
      draft: { service: "DIRECTO", amount: 5_000 },
    });
    if (result?.kind !== "entry") throw new Error("expected entry");
    expect(result.draft.directLabel).toBeTruthy();
  });
});

describe("parseShorthandLine — rejects unrecognized lines instead of guessing", () => {
  it("rejects a line matching no known shorthand pattern", () => {
    const result = parseShorthandLine("esto no tiene formato", "General");
    expect(result?.kind).toBe("error");
  });

  it("rejects a line whose service abbreviation is unknown instead of falling through to a default", () => {
    const result = parseShorthandLine("Cliente 100 PAYPAL (1/2)", "General");
    expect(result?.kind).toBe("error");
  });

  it("rejects an invalid numeric rate token instead of substituting 0", () => {
    const result = parseShorthandLine("Bladimir 30k CUP (abc/975)", "General");
    expect(result?.kind).toBe("error");
  });

  it("rejects an invalid amount token", () => {
    const result = parseShorthandLine("Bladimir notanumber CUP (240/975)", "General");
    expect(result?.kind).toBe("error");
  });
});

describe("shorthand parsing composed with the formula engine", () => {
  it("creates a RECARGA entry with 6,200 substituted for 6.2k (spec scenario, end to end)", () => {
    const parsed = parseShorthandLine("• Onaisy 1 rec promo(23.1/6.2k/240)", "General");
    if (parsed?.kind !== "entry") throw new Error("expected entry");

    const entry = normalizeManualEntry({
      id: "shorthand-1",
      date: "2026-01-05",
      amountCurrency: "GYD",
      ...parsed.draft,
    });

    expect(entry.service).toBe("RECARGA");
    expect(entry.facturadoGyd).toBeCloseTo(6_200, 6);
    expect(entry.invertidoGyd).toBeCloseTo(5_544, 6);
    expect(entry.retornoGyd).toBeCloseTo(656, 6);
  });

  it("a CUP shorthand draft with no cupGlobalRate still throws instead of defaulting to 3.0", () => {
    const parsed = parseShorthandLine("Bladimir 30k CUP (240/975)", "General");
    if (parsed?.kind !== "entry") throw new Error("expected entry");

    expect(() =>
      normalizeManualEntry({
        id: "shorthand-2",
        date: "2026-01-05",
        amountCurrency: "CUP",
        ...parsed.draft,
      }),
    ).toThrow(CalculatorValidationError);
  });
});
