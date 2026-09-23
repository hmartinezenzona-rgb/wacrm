import { describe, expect, it } from "vitest";
import { calculateEntry } from "./formulas";
import { CalculatorValidationError } from "./errors";

// Every expected value below is transcribed from the owner's reference
// calculator (`CALCULADORA OSMANY.txt`, function procesarTexto) using the
// same example rows as its "Guía Rápida de Formatos de Registro".

describe("calculateEntry — CUP", () => {
  it("facturado = monto / tarifaCupGlobal; invertido = (monto / tasaCupUsdt) * costoUsdtGyd", () => {
    // "• Fran 50k CUP (235/980)" with tarifaCupGlobal = 3.0
    const result = calculateEntry({
      service: "CUP",
      amount: 50_000,
      costGyd: 235,
      cupGlobalRate: 3,
      cupRate: 980,
    });
    expect(result.facturadoGyd).toBeCloseTo(16_666.666666666668, 6);
    expect(result.invertidoGyd).toBeCloseTo(11_989.795918367348, 6);
    expect(result.retornoGyd).toBeCloseTo(4_676.8707482993195, 6);
  });

  it("does not mix cupGlobalRate (facturado) with saleGyd — a stray saleGyd must not affect the result", () => {
    const withoutSaleGyd = calculateEntry({
      service: "CUP",
      amount: 50_000,
      costGyd: 235,
      cupGlobalRate: 3,
      cupRate: 980,
    });
    const withStraySaleGyd = calculateEntry({
      service: "CUP",
      amount: 50_000,
      costGyd: 235,
      cupGlobalRate: 3,
      cupRate: 980,
      saleGyd: 999,
    });
    expect(withStraySaleGyd).toEqual(withoutSaleGyd);
  });

  it("rejects a zero cupGlobalRate (division by zero) instead of returning Infinity", () => {
    expect(() =>
      calculateEntry({
        service: "CUP",
        amount: 50_000,
        costGyd: 235,
        cupGlobalRate: 0,
        cupRate: 980,
      }),
    ).toThrow(CalculatorValidationError);
  });

  it("rejects a zero cupRate", () => {
    expect(() =>
      calculateEntry({
        service: "CUP",
        amount: 50_000,
        costGyd: 235,
        cupGlobalRate: 3,
        cupRate: 0,
      }),
    ).toThrow(CalculatorValidationError);
  });
});

describe("calculateEntry — ZELLE", () => {
  it("without discount: invertido = monto * costoGyd; facturado = monto * ventaGyd", () => {
    // "• Julié 2.8k Zelle" without the optional %/cost/sale discount piece
    const result = calculateEntry({
      service: "ZELLE",
      amount: 2_800,
      costGyd: 235,
      saleGyd: 250,
    });
    expect(result.facturadoGyd).toBeCloseTo(700_000, 6);
    expect(result.invertidoGyd).toBeCloseTo(658_000, 6);
    expect(result.retornoGyd).toBeCloseTo(42_000, 6);
  });

  it("with discount: invertido uses monto adjusted by the discount before costoGyd", () => {
    // "• Julié 2.8k Zelle (3%/235/250)"
    const result = calculateEntry({
      service: "ZELLE",
      amount: 2_800,
      discountPct: 3,
      costGyd: 235,
      saleGyd: 250,
    });
    expect(result.facturadoGyd).toBeCloseTo(700_000, 6);
    expect(result.invertidoGyd).toBeCloseTo(638_834.9514563106, 4);
    expect(result.retornoGyd).toBeCloseTo(61_165.04854368942, 4);
  });
});

describe("calculateEntry — CLASICA / TROPICAL (share the ZELLE/MLC formula)", () => {
  it.each(["MLC", "CLASICA", "TROPICAL"] as const)(
    "%s: applies the discount the same way ZELLE does",
    (service) => {
      // "• Pedro 150 MLC (30%/240/245)"
      const result = calculateEntry({
        service,
        amount: 150,
        discountPct: 30,
        costGyd: 240,
        saleGyd: 245,
      });
      expect(result.facturadoGyd).toBeCloseTo(36_750, 4);
      expect(result.invertidoGyd).toBeCloseTo(27_692.307692307695, 4);
      expect(result.retornoGyd).toBeCloseTo(9_057.692307692309, 4);
    },
  );
});

describe("calculateEntry — USDT", () => {
  it("invertido = monto * costoGyd; facturado = monto * ventaGyd (no discount)", () => {
    // "• Carlos 1k usdt (235/260)"
    const result = calculateEntry({
      service: "USDT",
      amount: 1_000,
      costGyd: 235,
      saleGyd: 260,
    });
    expect(result.facturadoGyd).toBeCloseTo(260_000, 6);
    expect(result.invertidoGyd).toBeCloseTo(235_000, 6);
    expect(result.retornoGyd).toBeCloseTo(25_000, 6);
  });
});

describe("calculateEntry — RECARGA / SALDO_MOVIL", () => {
  it("RECARGA: invertido = monto * usdtCostoUnit * tasaUsdtGyd; facturado = monto * ventaUnitGyd", () => {
    // "• Josefa 1 rec promo (23.1/6.2k/242)" — note 6.2k parses as 6200
    const result = calculateEntry({
      service: "RECARGA",
      amount: 1,
      costGyd: 23.1,
      saleGyd: 6_200,
      cupRate: 242,
    });
    expect(result.facturadoGyd).toBeCloseTo(6_200, 6);
    expect(result.invertidoGyd).toBeCloseTo(5_590.200000000001, 6);
    expect(result.retornoGyd).toBeCloseTo(609.7999999999993, 6);
  });

  it("SALDO_MOVIL: same formula shape as RECARGA", () => {
    // "• Carlos 2 saldo movil (1.25/1k/242.21)"
    const result = calculateEntry({
      service: "SALDO_MOVIL",
      amount: 2,
      costGyd: 1.25,
      saleGyd: 1_000,
      cupRate: 242.21,
    });
    expect(result.facturadoGyd).toBeCloseTo(2_000, 6);
    expect(result.invertidoGyd).toBeCloseTo(605.525, 6);
    expect(result.retornoGyd).toBeCloseTo(1_394.475, 6);
  });
});

describe("calculateEntry — DIRECTO", () => {
  it("facturado = monto, invertido = 0, retorno = monto (clean profit)", () => {
    // "• Iza 1 ext visa 5k GYD"
    const result = calculateEntry({ service: "DIRECTO", amount: 5_000 });
    expect(result.facturadoGyd).toBe(5_000);
    expect(result.invertidoGyd).toBe(0);
    expect(result.retornoGyd).toBe(5_000);
  });

  it("ignores stray cost/sale/cupRate fields instead of using them", () => {
    const result = calculateEntry({
      service: "DIRECTO",
      amount: 5_000,
      costGyd: 999,
      saleGyd: 999,
      cupRate: 999,
    });
    expect(result.facturadoGyd).toBe(5_000);
    expect(result.invertidoGyd).toBe(0);
  });
});

describe("calculateEntry — invalid/missing numeric inputs raise explicit errors", () => {
  it("missing amount throws CalculatorValidationError, never NaN", () => {
    expect(() =>
      // @ts-expect-error deliberately omitting a required field
      calculateEntry({ service: "USDT", costGyd: 235, saleGyd: 260 }),
    ).toThrow(CalculatorValidationError);
  });

  it("amount of zero is rejected", () => {
    expect(() =>
      calculateEntry({ service: "DIRECTO", amount: 0 }),
    ).toThrow(CalculatorValidationError);
  });

  it("negative amount is rejected", () => {
    expect(() =>
      calculateEntry({ service: "DIRECTO", amount: -100 }),
    ).toThrow(CalculatorValidationError);
  });

  it("NaN amount is rejected", () => {
    expect(() =>
      calculateEntry({ service: "USDT", amount: Number.NaN, costGyd: 1, saleGyd: 1 }),
    ).toThrow(CalculatorValidationError);
  });

  it("CUP without costGyd throws (no silent 0)", () => {
    expect(() =>
      calculateEntry({ service: "CUP", amount: 50_000, cupGlobalRate: 3, cupRate: 980 }),
    ).toThrow(CalculatorValidationError);
  });

  it("CUP without cupRate throws (no silent default of 980)", () => {
    expect(() =>
      calculateEntry({ service: "CUP", amount: 50_000, costGyd: 235, cupGlobalRate: 3 }),
    ).toThrow(CalculatorValidationError);
  });

  it("CUP without cupGlobalRate throws (no silent default of 3.0)", () => {
    expect(() =>
      calculateEntry({ service: "CUP", amount: 50_000, costGyd: 235, cupRate: 980 }),
    ).toThrow(CalculatorValidationError);
  });

  it("ZELLE without saleGyd throws", () => {
    expect(() =>
      calculateEntry({ service: "ZELLE", amount: 2_800, costGyd: 235 }),
    ).toThrow(CalculatorValidationError);
  });

  it("ZELLE with a negative discountPct throws", () => {
    expect(() =>
      calculateEntry({
        service: "ZELLE",
        amount: 2_800,
        discountPct: -5,
        costGyd: 235,
        saleGyd: 250,
      }),
    ).toThrow(CalculatorValidationError);
  });

  it("RECARGA without cupRate throws", () => {
    expect(() =>
      calculateEntry({ service: "RECARGA", amount: 1, costGyd: 23.1, saleGyd: 6_200 }),
    ).toThrow(CalculatorValidationError);
  });

  it("an unknown service string throws instead of falling through silently", () => {
    expect(() =>
      calculateEntry({
        // @ts-expect-error deliberately invalid service
        service: "PAYPAL",
        amount: 100,
      }),
    ).toThrow(CalculatorValidationError);
  });
});
