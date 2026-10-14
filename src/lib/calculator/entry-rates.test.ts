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
    expect(canEditEntryRates(entry({ source: "manual" }))).toEqual(none);
    expect(canEditEntryRates(entry({ status: "verified_pending" }))).toEqual(none);
  });
});
