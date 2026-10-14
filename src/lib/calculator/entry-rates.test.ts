import { describe, expect, it } from "vitest";
import {
  canEditEntryRates,
  mapEntryRateSnapshot,
  recomputeInvestment,
  type EntryRateInput,
} from "./entry-rates";

function entry(overrides: Partial<EntryRateInput> = {}): EntryRateInput {
  return {
    source: "completed_operation",
    status: "completed",
    service: "CUP",
    amount: 106000,
    facturadoGyd: 35000,
    cupRate: 1060,
    usdtBuyGyd: 205,
    costGyd: null,
    basisGyd: null,
    saleGyd: null,
    ...overrides,
  };
}

describe("mapEntryRateSnapshot", () => {
  it("coerces numeric strings and keeps null/absent columns null", () => {
    expect(
      mapEntryRateSnapshot({
        cup_global_rate: "3",
        cup_rate: "1060",
        usdt_buy_gyd: 205,
        usdt_sell_gyd: null,
        cost_gyd: "1.5",
      }),
    ).toEqual({
      cupGlobalRate: 3,
      cupRate: 1060,
      usdtBuyGyd: 205,
      usdtSellGyd: null,
      costGyd: 1.5,
      basisGyd: null,
      saleGyd: null,
    });
  });
});

describe("recomputeInvestment (mirrors crm_corregir_tasas_entrada_calculadora)", () => {
  it("CUP: (amount / cup_rate) * usdt_buy_gyd, retorno = facturado - invertido", () => {
    const result = recomputeInvestment(entry(), { cupRate: 960 });
    expect(result?.invertidoGyd).toBeCloseTo((106000 / 960) * 205, 6);
    expect(result?.retornoGyd).toBeCloseTo(35000 - (106000 / 960) * 205, 6);
  });

  it("CUP: both rates at once; an omitted rate keeps the stored one", () => {
    expect(recomputeInvestment(entry(), { usdtBuyGyd: 200, cupRate: 1000 })?.invertidoGyd).toBeCloseTo(21200, 6);
    expect(recomputeInvestment(entry(), { usdtBuyGyd: 200 })?.invertidoGyd).toBeCloseTo((106000 / 1060) * 200, 6);
  });

  it("USD services (ZELLE, CLASICA, TROPICAL, EFECTIVO, MLC, USDT): amount * usdt_buy_gyd", () => {
    for (const service of ["ZELLE", "CLASICA", "TROPICAL", "EFECTIVO", "MLC", "USDT"]) {
      const result = recomputeInvestment(entry({ service, amount: 100, facturadoGyd: 21500, cupRate: 1060 }), { usdtBuyGyd: 190 });
      expect(result).toEqual({ invertidoGyd: 19000, retornoGyd: 2500 });
    }
  });

  it("RECARGA: units * USDT cost * usdt_buy_gyd", () => {
    const result = recomputeInvestment(
      entry({ service: "RECARGA", amount: 2, facturadoGyd: 2000, costGyd: 1.5, cupRate: 205 }),
      { usdtBuyGyd: 200 },
    );
    expect(result).toEqual({ invertidoGyd: 600, retornoGyd: 1400 });
  });

  it("SALDO_MOVIL: (basis / package price) * USDT cost * usdt_buy_gyd, not the saldo units in amount", () => {
    const result = recomputeInvestment(
      entry({ service: "SALDO_MOVIL", amount: 1080, facturadoGyd: 3000, costGyd: 2, basisGyd: 3000, saleGyd: 1000 }),
      { usdtBuyGyd: 200 },
    );
    expect(result).toEqual({ invertidoGyd: 1200, retornoGyd: 1800 });
  });

  it("SALDO_MOVIL without a whole package count -> null", () => {
    expect(
      recomputeInvestment(entry({ service: "SALDO_MOVIL", costGyd: 2, basisGyd: 3500, saleGyd: 1000 }), { usdtBuyGyd: 200 }),
    ).toBeNull();
  });

  it("COMBO and VISA have no rates -> null", () => {
    expect(recomputeInvestment(entry({ service: "COMBO", usdtBuyGyd: null, cupRate: null }), { usdtBuyGyd: 200 })).toBeNull();
    expect(recomputeInvestment(entry({ service: "VISA", usdtBuyGyd: null, cupRate: null }), { usdtBuyGyd: 200 })).toBeNull();
  });

  it("a cup_rate for a non-CUP service, or non-positive rates -> null", () => {
    expect(recomputeInvestment(entry({ service: "ZELLE", amount: 100 }), { cupRate: 960 })).toBeNull();
    expect(recomputeInvestment(entry(), { usdtBuyGyd: 0 })).toBeNull();
    expect(recomputeInvestment(entry(), { cupRate: -1 })).toBeNull();
    expect(recomputeInvestment(entry(), { usdtBuyGyd: Number.NaN })).toBeNull();
  });

  it("a snapshot without what the formula needs -> null", () => {
    expect(recomputeInvestment(entry({ usdtBuyGyd: null }), {})).toBeNull();
    expect(recomputeInvestment(entry({ cupRate: null }), { usdtBuyGyd: 200 })).toBeNull();
    expect(recomputeInvestment(entry({ facturadoGyd: null }), { cupRate: 960 })).toBeNull();
    expect(recomputeInvestment(entry({ service: "RECARGA", costGyd: null }), { usdtBuyGyd: 200 })).toBeNull();
  });
});

describe("canEditEntryRates", () => {
  it("CUP: both rates editable", () => {
    expect(canEditEntryRates(entry())).toEqual({ buy: true, cup: true });
  });

  it("other costed services: only the buy rate", () => {
    for (const service of ["ZELLE", "CLASICA", "RECARGA", "SALDO_MOVIL"]) {
      expect(canEditEntryRates(entry({ service }))).toEqual({ buy: true, cup: false });
    }
  });

  it("nothing editable for COMBO/VISA, manual or non-completed entries", () => {
    const none = { buy: false, cup: false };
    expect(canEditEntryRates(entry({ service: "COMBO" }))).toEqual(none);
    expect(canEditEntryRates(entry({ service: "VISA" }))).toEqual(none);
    expect(canEditEntryRates(entry({ status: "verified_pending" }))).toEqual(none);
  });

  it("manual rows are editable for the services the manual calculator costs with the plain formulas", () => {
    expect(canEditEntryRates(entry({ source: "manual", service: "CUP" }))).toEqual({ buy: true, cup: true });
    for (const service of ["ZELLE", "CLASICA", "MLC", "TROPICAL", "USDT"]) {
      expect(canEditEntryRates(entry({ source: "manual", service }))).toEqual({ buy: true, cup: false });
    }
  });

  it("manual RECARGA, SALDO_MOVIL, DIRECTO, EFECTIVO, COMBO and VISA stay refused", () => {
    for (const service of ["RECARGA", "SALDO_MOVIL", "DIRECTO", "EFECTIVO", "COMBO", "VISA"]) {
      expect(canEditEntryRates(entry({ source: "manual", service }))).toEqual({ buy: false, cup: false });
    }
  });
});

describe("recomputeInvestment on a manual row (no stored snapshot)", () => {
  const manual = (overrides: Partial<EntryRateInput> = {}) =>
    entry({ source: "manual", cupRate: null, usdtBuyGyd: null, ...overrides });

  it("CUP needs both rates: 15000 CUP at 960 and 240 GYD gives 3750 and retorno 1250", () => {
    const row = manual({ amount: 15000, facturadoGyd: 5000 });
    expect(recomputeInvestment(row, { usdtBuyGyd: 240, cupRate: 960 })).toEqual({ invertidoGyd: 3750, retornoGyd: 1250 });
    expect(recomputeInvestment(row, { usdtBuyGyd: 240 })).toBeNull();
    expect(recomputeInvestment(row, { cupRate: 960 })).toBeNull();
  });

  it("ZELLE needs the buy rate: amount * buy", () => {
    const row = manual({ service: "ZELLE", amount: 100, facturadoGyd: 26000 });
    expect(recomputeInvestment(row, { usdtBuyGyd: 240 })).toEqual({ invertidoGyd: 24000, retornoGyd: 2000 });
    expect(recomputeInvestment(row, {})).toBeNull();
  });

  it("manual services outside the supported set recompute to null", () => {
    for (const service of ["RECARGA", "SALDO_MOVIL", "DIRECTO", "EFECTIVO"]) {
      expect(recomputeInvestment(manual({ service, costGyd: 1.5, basisGyd: 1000, saleGyd: 500 }), { usdtBuyGyd: 240 })).toBeNull();
    }
  });
});

describe("recomputeInvestment on a discounted manual line", () => {
  const manual = (overrides: Partial<EntryRateInput> = {}): EntryRateInput =>
    entry({ source: "manual", service: "CLASICA", amount: 76, facturadoGyd: 19760, cupRate: null, usdtBuyGyd: null, discountPct: 3, ...overrides });

  it("uses the manual formula amount / (1 + pct / 100) * buy, retorno = facturado - invertido", () => {
    const result = recomputeInvestment(manual(), { usdtBuyGyd: 230 });
    expect(result?.invertidoGyd).toBeCloseTo((76 / 1.03) * 230, 9);
    expect(result?.retornoGyd).toBeCloseTo(19760 - (76 / 1.03) * 230, 9);
  });

  it("applies to ZELLE, MLC and TROPICAL too, and ignores a discount on CUP and USDT", () => {
    for (const service of ["ZELLE", "MLC", "TROPICAL"]) {
      expect(recomputeInvestment(manual({ service }), { usdtBuyGyd: 230 })?.invertidoGyd).toBeCloseTo((76 / 1.03) * 230, 9);
    }
    expect(recomputeInvestment(manual({ service: "USDT" }), { usdtBuyGyd: 230 })?.invertidoGyd).toBeCloseTo(76 * 230, 9);
    expect(recomputeInvestment(manual({ service: "CUP", amount: 15000, cupRate: 960 }), { usdtBuyGyd: 240 })?.invertidoGyd).toBeCloseTo(3750, 9);
  });

  it("no discount or a zero one keeps amount * buy; a chat-fed entry never takes a discount", () => {
    expect(recomputeInvestment(manual({ discountPct: 0 }), { usdtBuyGyd: 230 })?.invertidoGyd).toBeCloseTo(76 * 230, 9);
    expect(recomputeInvestment(manual({ discountPct: null }), { usdtBuyGyd: 230 })?.invertidoGyd).toBeCloseTo(76 * 230, 9);
    expect(recomputeInvestment(entry({ source: "completed_operation", service: "CLASICA", amount: 76, usdtBuyGyd: 238, discountPct: 3 }), {})?.invertidoGyd)
      .toBeCloseTo(76 * 238, 9);
  });
});
