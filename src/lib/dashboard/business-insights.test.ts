import { describe, expect, it } from "vitest";
import type { LedgerEntry } from "@/lib/calculator/ledger-read-model";
import { destinationBreakdownFrom, topClientsFrom } from "./business-insights";

/** Minimal `LedgerEntry` builder — only the fields each test cares
 *  about need overriding, everything else gets a safe default so
 *  every test stays readable. */
function entry(overrides: Partial<LedgerEntry> = {}): LedgerEntry {
  return {
    id: "e1",
    operationId: null,
    source: "completed_operation",
    status: "completed",
    service: "remesa",
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

describe("topClientsFrom", () => {
  it("groups entries by customerName and sums facturadoGyd", () => {
    const entries = [
      entry({ id: "1", customerName: "Alice", facturadoGyd: 1000 }),
      entry({ id: "2", customerName: "Alice", facturadoGyd: 500 }),
      entry({ id: "3", customerName: "Bob", facturadoGyd: 300 }),
    ];

    const result = topClientsFrom(entries);

    expect(result).toContainEqual({
      customerName: "Alice",
      operationCount: 2,
      facturadoGyd: 1500,
    });
    expect(result).toContainEqual({
      customerName: "Bob",
      operationCount: 1,
      facturadoGyd: 300,
    });
  });

  it("sorts clients by facturadoGyd descending", () => {
    const entries = [
      entry({ id: "1", customerName: "Small", facturadoGyd: 100 }),
      entry({ id: "2", customerName: "Big", facturadoGyd: 9000 }),
      entry({ id: "3", customerName: "Medium", facturadoGyd: 500 }),
    ];

    const result = topClientsFrom(entries);

    expect(result.map((c) => c.customerName)).toEqual([
      "Big",
      "Medium",
      "Small",
    ]);
  });

  it("caps the result at `limit` (default 5)", () => {
    const entries = Array.from({ length: 8 }, (_, i) =>
      entry({
        id: `${i}`,
        customerName: `Client ${i}`,
        facturadoGyd: (i + 1) * 100,
      }),
    );

    expect(topClientsFrom(entries)).toHaveLength(5);
    expect(topClientsFrom(entries, 3)).toHaveLength(3);
    expect(topClientsFrom(entries, 100)).toHaveLength(8);
  });

  it("buckets entries with customerName === null together", () => {
    const entries = [
      entry({ id: "1", customerName: null, facturadoGyd: 200 }),
      entry({ id: "2", customerName: null, facturadoGyd: 300 }),
      entry({ id: "3", customerName: "Alice", facturadoGyd: 50 }),
    ];

    const result = topClientsFrom(entries);

    expect(result).toContainEqual({
      customerName: null,
      operationCount: 2,
      facturadoGyd: 500,
    });
  });

  it("only counts status === 'completed' entries, mirroring ledgerTotals()", () => {
    const entries = [
      entry({ id: "1", customerName: "Alice", status: "completed", facturadoGyd: 1000 }),
      entry({ id: "2", customerName: "Alice", status: "verified_pending", facturadoGyd: 5000 }),
      entry({ id: "3", customerName: "Alice", status: "void", facturadoGyd: 9000 }),
    ];

    const result = topClientsFrom(entries);

    expect(result).toEqual([
      { customerName: "Alice", operationCount: 1, facturadoGyd: 1000 },
    ]);
  });
});

describe("destinationBreakdownFrom", () => {
  it("groups entries by amountCurrency and sums facturadoGyd", () => {
    const entries = [
      entry({ id: "1", amountCurrency: "USD", facturadoGyd: 1000 }),
      entry({ id: "2", amountCurrency: "USD", facturadoGyd: 500 }),
      entry({ id: "3", amountCurrency: "CUP", facturadoGyd: 300 }),
    ];

    const result = destinationBreakdownFrom(entries);

    expect(result).toContainEqual({
      currency: "USD",
      operationCount: 2,
      facturadoGyd: 1500,
    });
    expect(result).toContainEqual({
      currency: "CUP",
      operationCount: 1,
      facturadoGyd: 300,
    });
  });

  it("sorts currencies by facturadoGyd descending", () => {
    const entries = [
      entry({ id: "1", amountCurrency: "CUP", facturadoGyd: 100 }),
      entry({ id: "2", amountCurrency: "USD", facturadoGyd: 9000 }),
    ];

    const result = destinationBreakdownFrom(entries);

    expect(result.map((c) => c.currency)).toEqual(["USD", "CUP"]);
  });

  it("only counts status === 'completed' entries, mirroring ledgerTotals()", () => {
    const entries = [
      entry({ id: "1", amountCurrency: "USD", status: "completed", facturadoGyd: 1000 }),
      entry({ id: "2", amountCurrency: "USD", status: "verified_pending", facturadoGyd: 5000 }),
      entry({ id: "3", amountCurrency: "USD", status: "void", facturadoGyd: 9000 }),
    ];

    const result = destinationBreakdownFrom(entries);

    expect(result).toEqual([
      { currency: "USD", operationCount: 1, facturadoGyd: 1000 },
    ]);
  });
});
