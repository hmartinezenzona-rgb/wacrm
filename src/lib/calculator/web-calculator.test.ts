import { describe, expect, it } from "vitest";
import { parseMonto, procesarTexto } from "./web-calculator";

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
