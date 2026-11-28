import { describe, expect, it } from "vitest";
import { parseManualLineRates, parseManualUnitLine, parseMonto, procesarTexto } from "./web-calculator";

describe("native legacy web calculator", () => {
  it("parses k suffixes and thousands separators like the reference calculator", () => {
    expect(parseMonto("30k")).toBe(30_000);
    expect(parseMonto("4,081.64 usdt")).toBe(4_081.64);
  });

  it("reproduces the Zelle, USDT and CUP formulas", () => {
    const result = procesarTexto([
      "Lunes 7",
      "• Jaila 150 Zelle (240/260)",
      "• Brayan 469.23 USDT (242.21/260)",
      "• Bladimir 30k CUP (240/975)",
    ].join("\n"), 3);

    expect(result.operations).toHaveLength(3);
    expect(result.operations[0]).toMatchObject({ cliente: "Jaila", monto: 150, tipo: "ZELLE", fact: 39_000, inv: 36_000 });
    expect(result.operations[1]).toMatchObject({ cliente: "Brayan", monto: 469.23, tipo: "USDT" });
    expect(result.operations[2]).toMatchObject({ cliente: "Bladimir", monto: 30_000, tipo: "CUP", fact: 10_000 });
    expect(result.totals.fact).toBeCloseTo(39_000 + 469.23 * 260 + 10_000, 8);
  });

  it("keeps unrecognised lines in the audit without counting them", () => {
    const result = procesarTexto("Lunes 7\nesto no tiene formato", 3);
    expect(result.operations).toHaveLength(1);
    expect(result.operations[0]).toMatchObject({ error: true, raw: "esto no tiene formato" });
    expect(result.totals).toEqual({ fact: 0, inv: 0, ret: 0 });
  });
});

describe("parseManualLineRates (the rates a typed line was quoted with)", () => {
  it("reads buy and CUP rate from a CUP line", () => {
    expect(parseManualLineRates("• Marlene 15,000 cup (240/960)")).toEqual({ buy: 240, sell: null, cupRate: 960, discountPct: 0 });
  });

  it("reads buy and sale from a Zelle line", () => {
    expect(parseManualLineRates("• Michel 50 Zelle (238/260)")).toEqual({ buy: 238, sell: 260, cupRate: null, discountPct: 0 });
  });

  it("reads the discount of a discounted line and shifts the rates behind it", () => {
    expect(parseManualLineRates("• Zulemys 76 Clásica (3%/238/260)")).toEqual({ buy: 238, sell: 260, cupRate: null, discountPct: 3 });
  });

  it("reads decimal discounts the way the calculator does (parseFloat: 3.5 and 3,5 -> 3)", () => {
    expect(parseManualLineRates("• A 100 Zelle (3.5%/238/260)")?.discountPct).toBe(3.5);
    expect(parseManualLineRates("• A 100 Zelle (3,5%/238/260)")?.discountPct).toBe(3);
  });

  it("returns null for a line without rates, a day header, an error line or a direct service", () => {
    expect(parseManualLineRates("• Iza 100 Zelle")).toBeNull();
    expect(parseManualLineRates("Martes 6")).toBeNull();
    expect(parseManualLineRates("esto no tiene formato")).toBeNull();
    expect(parseManualLineRates("• Iza visa 4000")).toBeNull();
    expect(parseManualLineRates(null)).toBeNull();
  });

  it("agrees with procesarTexto on the discounted line", () => {
    const rates = parseManualLineRates("• Zulemys 76 Clásica (3%/238/260)")!;
    const op = procesarTexto("• Zulemys 76 Clásica (3%/238/260)", 3).operations[0] as { inv: number };
    expect(op.inv).toBeCloseTo((76 / (1 + rates.discountPct / 100)) * rates.buy!, 9);
  });
});

describe("parseManualUnitLine (cost and buy rate of a typed RECARGA / SALDO MOVIL line)", () => {
  it("reads cost, sale and buy from a recharge line", () => {
    expect(parseManualUnitLine("• Onaisy 1 rec promo(23.1/6.2k/240)")).toEqual({ cost: 23.1, sale: 6200, buy: 240 });
  });

  it("reads a saldo line", () => {
    expect(parseManualUnitLine("• Carlos 2 saldo movil (1.25/1k/242.21)")).toEqual({ cost: 1.25, sale: 1000, buy: 242.21 });
  });

  it("a slot that is missing or not above zero is null", () => {
    expect(parseManualUnitLine("• Raro 1 rec promo")).toBeNull();
    expect(parseManualUnitLine("• Onaisy 1 rec promo(23.1)")).toEqual({ cost: 23.1, sale: null, buy: null });
    expect(parseManualUnitLine("• Onaisy 1 rec promo(0/6.2k/240)")).toEqual({ cost: null, sale: 6200, buy: 240 });
  });

  it("is null for any other service, a day header or an unreadable line", () => {
    expect(parseManualUnitLine("• Marlene 15,000 cup (240/960)")).toBeNull();
    expect(parseManualUnitLine("Miércoles 5")).toBeNull();
    expect(parseManualUnitLine("esto no tiene formato")).toBeNull();
    expect(parseManualUnitLine(null)).toBeNull();
  });
});
