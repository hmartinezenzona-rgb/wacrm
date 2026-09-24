import { describe, expect, it } from "vitest";
import type { LedgerEntry } from "@/lib/calculator/ledger-read-model";
import { computeMarginPct, serviceProfitabilityFrom } from "./service-profitability";

/** Minimal `LedgerEntry` builder — only the fields each test cares
 *  about need overriding, everything else gets a safe default so
 *  every test stays readable. Same shape as business-insights.test.ts's
 *  builder. */
function entry(overrides: Partial<LedgerEntry> = {}): LedgerEntry {
  return {
    id: "e1",
    operationId: null,
    source: "completed_operation",
    status: "completed",
    service: "CUP",
    customerName: "Jane Doe",
    amount: 100,
    amountCurrency: "USD",
    entryDate: "2026-09-24",
    facturadoGyd: 1000,
    invertidoGyd: 800,
    retornoGyd: 200,
    missingRates: [],
    rateVersionId: null,
    deliveryMode: null,
    voidedAt: null,
    voidReason: null,
    completedAt: "2026-09-24T00:00:00Z",
    ...overrides,
  };
}

describe("serviceProfitabilityFrom", () => {
  it("groups entries by service and sums facturadoGyd/retornoGyd", () => {
    const entries = [
      entry({ id: "1", service: "CUP", facturadoGyd: 1000, retornoGyd: 200 }),
      entry({ id: "2", service: "CUP", facturadoGyd: 500, retornoGyd: 100 }),
      entry({ id: "3", service: "ZELLE", facturadoGyd: 300, retornoGyd: 50 }),
    ];

    const result = serviceProfitabilityFrom(entries);

    expect(result).toContainEqual({
      service: "CUP",
      operationCount: 2,
      facturadoGyd: 1500,
      retornoGyd: 300,
      margenPct: 20,
      ticketMedioGyd: 750,
    });
    expect(result).toContainEqual({
      service: "ZELLE",
      operationCount: 1,
      facturadoGyd: 300,
      retornoGyd: 50,
      margenPct: (50 / 300) * 100,
      ticketMedioGyd: 300,
    });
  });

  it("only counts status === 'completed' entries, mirroring ledgerTotals()", () => {
    const entries = [
      entry({ id: "1", service: "CUP", status: "completed", facturadoGyd: 1000, retornoGyd: 200 }),
      entry({ id: "2", service: "CUP", status: "verified_pending", facturadoGyd: 5000, retornoGyd: 900 }),
      entry({ id: "3", service: "CUP", status: "void", facturadoGyd: 9000, retornoGyd: 1000 }),
    ];

    const result = serviceProfitabilityFrom(entries);

    expect(result).toEqual([
      {
        service: "CUP",
        operationCount: 1,
        facturadoGyd: 1000,
        retornoGyd: 200,
        margenPct: 20,
        ticketMedioGyd: 1000,
      },
    ]);
  });

  it("returns margenPct: null when facturadoGyd is zero, never NaN/Infinity", () => {
    const entries = [
      entry({ id: "1", service: "TROPICAL", facturadoGyd: 0, retornoGyd: 0 }),
    ];

    const result = serviceProfitabilityFrom(entries);

    expect(result).toEqual([
      {
        service: "TROPICAL",
        operationCount: 1,
        facturadoGyd: 0,
        retornoGyd: 0,
        margenPct: null,
        ticketMedioGyd: 0,
      },
    ]);
  });

  it("computes ticketMedioGyd as facturadoGyd / operationCount", () => {
    const entries = [
      entry({ id: "1", service: "CLASICA", facturadoGyd: 900, retornoGyd: 90 }),
      entry({ id: "2", service: "CLASICA", facturadoGyd: 300, retornoGyd: 30 }),
      entry({ id: "3", service: "CLASICA", facturadoGyd: 300, retornoGyd: 30 }),
    ];

    const result = serviceProfitabilityFrom(entries);

    expect(result[0].ticketMedioGyd).toBe(500);
  });

  it("sorts services by retornoGyd descending", () => {
    const entries = [
      entry({ id: "1", service: "CUP", facturadoGyd: 100, retornoGyd: 10 }),
      entry({ id: "2", service: "ZELLE", facturadoGyd: 100, retornoGyd: 90 }),
      entry({ id: "3", service: "CLASICA", facturadoGyd: 100, retornoGyd: 50 }),
    ];

    const result = serviceProfitabilityFrom(entries);

    expect(result.map((r) => r.service)).toEqual(["ZELLE", "CLASICA", "CUP"]);
  });
});

describe("computeMarginPct", () => {
  it("computes retornoGyd / facturadoGyd * 100", () => {
    expect(computeMarginPct(1000, 200)).toBe(20);
  });

  it("returns null when facturadoGyd is 0, never NaN/Infinity", () => {
    expect(computeMarginPct(0, 0)).toBeNull();
    expect(computeMarginPct(0, 200)).toBeNull();
  });

  it("supports a negative margin (loss)", () => {
    expect(computeMarginPct(1000, -100)).toBe(-10);
  });
});
