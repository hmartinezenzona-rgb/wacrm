// Unit tests for the pure ledger row -> API payload mapping (Slice 9,
// tasks 9.8/9.9). Covers numeric string coercion, null passthrough, the
// historical-fact rule for missingRates (never recomputed against today's
// rates), and the completed-only totals rule.

import { describe, expect, it } from "vitest";
import {
  COMBO_COST_PENDING_MESSAGE,
  canResolveWithRates,
  isComboCostPending,
  ledgerTotals,
  mapLedgerEntry,
  mapRateVersion,
  type LedgerEntry,
  type LedgerEntryRow,
  type RateVersionRow,
} from "./ledger-read-model";

function row(overrides: Partial<LedgerEntryRow>): LedgerEntryRow {
  return {
    id: "entry-1",
    account_id: "account-1",
    source: "completed_operation",
    status: "completed",
    operation_id: "op-1",
    entry_date: "2026-09-10",
    customer_name: "Yaima Perez",
    service: "CUP",
    amount: 100,
    amount_currency: "GYD",
    facturado_gyd: 30000,
    invertido_gyd: 28000,
    retorno_gyd: 2000,
    cup_global_rate: 3,
    cup_rate: 1.05,
    usdt_buy_gyd: 145,
    usdt_sell_gyd: 148,
    rate_version_id: "rate-1",
    missing_inputs: [],
    delivery_mode: "proof_sent",
    voided_at: null,
    void_reason: null,
    completed_at: "2026-09-10T12:00:00Z",
    created_at: "2026-09-10T08:00:00Z",
    ...overrides,
  };
}

describe("mapLedgerEntry", () => {
  it("maps a completed entry, coercing numeric strings to numbers", () => {
    const entry = mapLedgerEntry(
      row({
        amount: "100.50",
        facturado_gyd: "30000.25",
        invertido_gyd: "28000",
        retorno_gyd: "2000.25",
      }),
    );

    expect(entry).toEqual<LedgerEntry>({
      id: "entry-1",
      operationId: "op-1",
      source: "completed_operation",
      status: "completed",
      service: "CUP",
      customerName: "Yaima Perez",
      amount: 100.5,
      amountCurrency: "GYD",
      entryDate: "2026-09-10",
      facturadoGyd: 30000.25,
      invertidoGyd: 28000,
      retornoGyd: 2000.25,
      missingRates: [],
      rateVersionId: "rate-1",
      deliveryMode: "proof_sent",
      voidedAt: null,
      voidReason: null,
      completedAt: "2026-09-10T12:00:00Z",
    });
  });

  it("keeps nullable financial fields null instead of coercing to zero", () => {
    const entry = mapLedgerEntry(
      row({
        status: "verified_pending",
        facturado_gyd: null,
        invertido_gyd: null,
        retorno_gyd: null,
        rate_version_id: null,
        missing_inputs: ["usdtSellGyd"],
      }),
    );

    expect(entry.facturadoGyd).toBeNull();
    expect(entry.invertidoGyd).toBeNull();
    expect(entry.retornoGyd).toBeNull();
    expect(entry.rateVersionId).toBeNull();
    expect(entry.missingRates).toEqual(["usdtSellGyd"]);
  });

  it("defaults missingRates to an empty array when missing_inputs is null", () => {
    const entry = mapLedgerEntry(row({ missing_inputs: null }));
    expect(entry.missingRates).toEqual([]);
  });

  it("never recomputes missingRates against today's rates -- it is the stored historical snapshot from when the entry was fed", () => {
    // A pending entry that was fed while usdtSellGyd was missing keeps that
    // fact forever, even if the account's rates are complete by the time
    // this row is read back later.
    const entry = mapLedgerEntry(
      row({ status: "verified_pending", missing_inputs: ["usdtSellGyd"] }),
    );
    expect(entry.missingRates).toEqual(["usdtSellGyd"]);
  });

  it("passes through void metadata", () => {
    const entry = mapLedgerEntry(
      row({
        status: "void",
        voided_at: "2026-09-11T09:00:00Z",
        void_reason: "duplicate entry",
      }),
    );
    expect(entry.status).toBe("void");
    expect(entry.voidedAt).toBe("2026-09-11T09:00:00Z");
    expect(entry.voidReason).toBe("duplicate entry");
  });

  it("passes through the manual source and null operationId", () => {
    const entry = mapLedgerEntry(row({ source: "manual", operation_id: null }));
    expect(entry.source).toBe("manual");
    expect(entry.operationId).toBeNull();
  });
});

describe("ledgerTotals", () => {
  function entry(overrides: Partial<LedgerEntry>): LedgerEntry {
    return {
      id: "entry-1",
      operationId: "op-1",
      source: "completed_operation",
      status: "completed",
      service: "CUP",
      customerName: "Yaima Perez",
      amount: 100,
      amountCurrency: "GYD",
      entryDate: "2026-09-10",
      facturadoGyd: 30000,
      invertidoGyd: 28000,
      retornoGyd: 2000,
      missingRates: [],
      rateVersionId: "rate-1",
      deliveryMode: null,
      voidedAt: null,
      voidReason: null,
      completedAt: "2026-09-10T12:00:00Z",
      ...overrides,
    };
  }

  it("sums only completed entries", () => {
    const totals = ledgerTotals([
      entry({ facturadoGyd: 30000, invertidoGyd: 28000, retornoGyd: 2000 }),
      entry({ facturadoGyd: 10000, invertidoGyd: 9000, retornoGyd: 1000 }),
    ]);

    expect(totals).toEqual({
      facturadoGyd: 40000,
      invertidoGyd: 37000,
      retornoGyd: 3000,
      count: 2,
    });
  });

  it("excludes verified_pending entries entirely -- they have no financial snapshot yet", () => {
    const totals = ledgerTotals([
      entry({ status: "completed", facturadoGyd: 30000, invertidoGyd: 28000, retornoGyd: 2000 }),
      entry({
        status: "verified_pending",
        facturadoGyd: null,
        invertidoGyd: null,
        retornoGyd: null,
      }),
    ]);

    expect(totals).toEqual({
      facturadoGyd: 30000,
      invertidoGyd: 28000,
      retornoGyd: 2000,
      count: 1,
    });
  });

  it("excludes void entries entirely -- reversed money never counts", () => {
    const totals = ledgerTotals([
      entry({ status: "completed", facturadoGyd: 30000, invertidoGyd: 28000, retornoGyd: 2000 }),
      entry({ status: "void", facturadoGyd: 5000, invertidoGyd: 4000, retornoGyd: 1000 }),
    ]);

    expect(totals).toEqual({
      facturadoGyd: 30000,
      invertidoGyd: 28000,
      retornoGyd: 2000,
      count: 1,
    });
  });

  it("returns all-zero totals for an empty ledger", () => {
    expect(ledgerTotals([])).toEqual({
      facturadoGyd: 0,
      invertidoGyd: 0,
      retornoGyd: 0,
      count: 0,
    });
  });
});

describe("mapRateVersion", () => {
  function rateRow(overrides: Partial<RateVersionRow>): RateVersionRow {
    return {
      id: "rate-1",
      account_id: "account-1",
      cup_global_rate: 3,
      usdt_buy_gyd: 145,
      usdt_sell_gyd: 148,
      usdt_sell_cup: 1.05,
      efectivo_usd_gyd: 290,
      recarga_costo_usdt: "4.5",
      set_by: "user-1",
      effective_at: "2026-09-10T08:00:00Z",
      ...overrides,
    };
  }

  it("maps all four rates, coercing numeric strings to numbers", () => {
    const rates = mapRateVersion(rateRow({ cup_global_rate: "3.25", usdt_buy_gyd: "145.5" }));

    expect(rates).toEqual({
      id: "rate-1",
      cupGlobalRate: 3.25,
      usdtBuyGyd: 145.5,
      usdtSellGyd: 148,
      usdtSellCup: 1.05,
      efectivoUsdGyd: 290,
      recargaCostoUsdt: 4.5,
      zelleSellGyd: null,
      zelleSellGyd1000: null,
      zelleSellGyd2000: null,
      effectiveAt: "2026-09-10T08:00:00Z",
      setBy: "user-1",
    });
  });

  it("maps the three Zelle tier prices, coercing numeric strings (migration 216)", () => {
    const rates = mapRateVersion(
      rateRow({ zelle_sell_gyd: "260", zelle_sell_gyd_1000: "250.5", zelle_sell_gyd_2000: 245 }),
    );
    expect([rates.zelleSellGyd, rates.zelleSellGyd1000, rates.zelleSellGyd2000]).toEqual([260, 250.5, 245]);
  });

  it("never substitutes a default for a null rate", () => {
    const rates = mapRateVersion(
      rateRow({
        cup_global_rate: null,
        usdt_buy_gyd: null,
        usdt_sell_gyd: null,
        usdt_sell_cup: null,
        efectivo_usd_gyd: null,
        recarga_costo_usdt: null,
      }),
    );

    expect(rates.cupGlobalRate).toBeNull();
    expect(rates.usdtBuyGyd).toBeNull();
    expect(rates.usdtSellGyd).toBeNull();
    expect(rates.usdtSellCup).toBeNull();
    expect(rates.efectivoUsdGyd).toBeNull();
    expect(rates.recargaCostoUsdt).toBeNull();
  });

  it("passes through a null set_by (system-set rate)", () => {
    const rates = mapRateVersion(rateRow({ set_by: null }));
    expect(rates.setBy).toBeNull();
  });
});

describe("COMBO ledger lines (migration 209)", () => {
  it("maps a priced combo: the deposit billed, the entered cost invested, no rates", () => {
    const entry = mapLedgerEntry(
      row({
        service: "COMBO",
        amount: "55000",
        amount_currency: "GYD",
        facturado_gyd: "55000",
        invertido_gyd: "41000",
        retorno_gyd: "14000",
        cup_global_rate: null,
        cup_rate: null,
        usdt_buy_gyd: null,
        usdt_sell_gyd: null,
        rate_version_id: null,
        missing_inputs: [],
      }),
    );

    expect(entry).toMatchObject({
      service: "COMBO",
      status: "completed",
      amount: 55000,
      amountCurrency: "GYD",
      facturadoGyd: 55000,
      invertidoGyd: 41000,
      retornoGyd: 14000,
      missingRates: [],
    });
    expect(isComboCostPending(entry)).toBe(false);
    expect(ledgerTotals([entry])).toMatchObject({ facturadoGyd: 55000, invertidoGyd: 41000, retornoGyd: 14000 });
  });

  it("a pending combo carries comboCosto, counts as zero, and is flagged as waiting for the cost", () => {
    const entry = mapLedgerEntry(
      row({
        service: "COMBO",
        status: "verified_pending",
        facturado_gyd: null,
        invertido_gyd: null,
        retorno_gyd: null,
        missing_inputs: ["comboCosto"],
      }),
    );

    expect(entry.missingRates).toEqual(["comboCosto"]);
    expect(isComboCostPending(entry)).toBe(true);
    expect(COMBO_COST_PENDING_MESSAGE).toBe("Falta el costo del combo: anótalo en el panel de la conversación");
    expect(ledgerTotals([entry]).count).toBe(0);
  });

  it("rates resolution is never offered for a COMBO line, only for a pending line of another service", () => {
    const combo = mapLedgerEntry(row({ service: "COMBO", status: "verified_pending", missing_inputs: ["comboCosto"] }));
    const cup = mapLedgerEntry(row({ service: "CUP", status: "verified_pending", missing_inputs: ["usdtSellCup"] }));
    const done = mapLedgerEntry(row({ service: "CUP", status: "completed" }));

    expect(canResolveWithRates(combo)).toBe(false);
    expect(canResolveWithRates(cup)).toBe(true);
    expect(canResolveWithRates(done)).toBe(false);
  });

  it("never offers rate resolution for VISA, and a completed VISA line maps as facturado = retorno", () => {
    const pendingVisa = mapLedgerEntry(row({ service: "VISA", status: "verified_pending", missing_inputs: [] }));
    const visa = mapLedgerEntry(
      row({ service: "VISA", status: "completed", amount: 15000, amount_currency: "GYD", facturado_gyd: 15000, invertido_gyd: 0, retorno_gyd: 15000 }),
    );

    expect(canResolveWithRates(pendingVisa)).toBe(false);
    expect(visa).toMatchObject({ service: "VISA", amountCurrency: "GYD", facturadoGyd: 15000, invertidoGyd: 0, retornoGyd: 15000 });
    expect(canResolveWithRates(visa)).toBe(false);
  });
});
