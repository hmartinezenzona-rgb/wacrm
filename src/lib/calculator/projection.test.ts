import { describe, expect, it } from "vitest";
import {
  materializeProjectedOperation,
  projectStructuredOperation,
} from "./projection";
import { calculateTotals } from "./totals";
import type { StructuredRemittanceCalculatorSource } from "./projection";

function source(overrides: Partial<StructuredRemittanceCalculatorSource> = {}): StructuredRemittanceCalculatorSource {
  return {
    operationId: "op-1",
    status: "completed",
    depositVerified: true,
    deliveryMethod: "cuban_card",
    destinationAmount: 50_000,
    destinationCurrency: "CUP",
    customerName: "Fran",
    completedAt: "2026-09-12T12:00:00Z",
    ...overrides,
  };
}

describe("structured operation calculator projection", () => {
  it.each([
    ["cuban_card", "CUP", "CUP"],
    ["zelle", "USD", "ZELLE"],
    ["usdt", "USDT", "USDT"],
    ["clasica", "USD", "CLASICA"],
    ["clásica", "USD", "CLASICA"],
    ["tropical", "USD", "TROPICAL"],
  ])("maps %s to %s", (deliveryMethod, currency, service) => {
    const result = projectStructuredOperation(source({ deliveryMethod, destinationCurrency: currency }));
    expect(result).toMatchObject({ kind: "candidate", candidate: { service, status: "completed", amount: 50_000, amountCurrency: currency } });
  });

  it("keeps a verified non-terminal operation visible but excluded from totals", () => {
    const result = projectStructuredOperation(source({ status: "ready", deliveryMethod: "zelle", destinationCurrency: "USD" }));
    expect(result).toMatchObject({ kind: "candidate", candidate: { status: "verified_pending" } });
    if (result.kind !== "candidate") throw new Error("expected candidate");
    const entry = materializeProjectedOperation(result.candidate, { costGyd: 235, saleGyd: 240 });
    expect(calculateTotals([entry])).toMatchObject({ count: 0, facturadoGyd: 0, invertidoGyd: 0 });
  });

  it.each([
    ["unverified deposit", source({ depositVerified: false }), "deposit_not_verified"],
    ["unknown method", source({ deliveryMethod: "other" }), "unknown_delivery_method"],
    ["cuban card with non-CUP", source({ destinationCurrency: "MLC" }), "incompatible_currency"],
    ["missing amount", source({ destinationAmount: null, sourceAmount: 30_000 } as Partial<StructuredRemittanceCalculatorSource>), "missing_amount"],
    ["missing currency", source({ destinationCurrency: null }), "missing_currency"],
  ])("rejects %s without guessing", (_label, input, reason) => {
    expect(projectStructuredOperation(input)).toEqual({ kind: "rejected", reason });
  });

  it("does not manufacture financial results while rates are absent", () => {
    const result = projectStructuredOperation(source());
    expect(result).toMatchObject({ kind: "candidate", candidate: { financialBlockers: ["costGyd", "cupRate", "cupGlobalRate"] } });
  });

  it("reuses the existing formula engine when rates are supplied", () => {
    const result = projectStructuredOperation(source());
    if (result.kind !== "candidate") throw new Error("expected candidate");
    const entry = materializeProjectedOperation(result.candidate, { costGyd: 235, cupRate: 980, cupGlobalRate: 3 });
    expect(entry.facturadoGyd).toBeCloseTo(16_666.666666666668, 10);
    expect(entry.invertidoGyd).toBeCloseTo(11_989.795918367347, 10);
    expect(entry.retornoGyd).toBeCloseTo(4_676.870748299321, 10);
  });

  it("carries the client's GYD deposit through the candidate without inferring anything from it yet", () => {
    const result = projectStructuredOperation(source({ sourceAmount: 24_000, sourceCurrency: "GYD" }));
    expect(result).toMatchObject({
      kind: "candidate",
      candidate: { amount: 50_000, sourceAmount: 24_000, sourceCurrency: "GYD" },
    });
  });

  it("finalizes ZELLE from the GYD deposit (ceil(source/sale)) instead of the stored destination amount", () => {
    const result = projectStructuredOperation(
      source({ deliveryMethod: "zelle", destinationCurrency: "USD", destinationAmount: 999, sourceAmount: 24_000, sourceCurrency: "GYD" }),
    );
    if (result.kind !== "candidate") throw new Error("expected candidate");
    const entry = materializeProjectedOperation(result.candidate, { costGyd: 240, saleGyd: 260 });
    expect(entry.amount).toBe(93);
    expect(entry.facturadoGyd).toBeCloseTo(24_180, 6);
    expect(entry.invertidoGyd).toBeCloseTo(22_320, 6);
    expect(entry.retornoGyd).toBeCloseTo(1_860, 6);
  });

  it("finalizes CUP from the GYD deposit (source * cupGlobalRate) instead of the stored destination amount", () => {
    const result = projectStructuredOperation(source({ destinationAmount: 999, sourceAmount: 5_000, sourceCurrency: "GYD" }));
    if (result.kind !== "candidate") throw new Error("expected candidate");
    const entry = materializeProjectedOperation(result.candidate, { costGyd: 240, cupRate: 975, cupGlobalRate: 3 });
    expect(entry.amount).toBe(15_000);
    expect(entry.facturadoGyd).toBeCloseTo(5_000, 6);
    expect(entry.invertidoGyd).toBeCloseTo(3_692.3076923076924, 10);
    expect(entry.retornoGyd).toBeCloseTo(1_307.6923076923076, 10);
  });

  it("never infers a deposit-based amount when the source currency isn't GYD", () => {
    const result = projectStructuredOperation(
      source({ deliveryMethod: "zelle", destinationCurrency: "USD", destinationAmount: 100, sourceAmount: 24_000, sourceCurrency: "USD" }),
    );
    if (result.kind !== "candidate") throw new Error("expected candidate");
    const entry = materializeProjectedOperation(result.candidate, { costGyd: 240, saleGyd: 260 });
    expect(entry.amount).toBe(100);
  });

  it("falls back to the destination amount when no deposit was carried through", () => {
    const result = projectStructuredOperation(source({ deliveryMethod: "zelle", destinationCurrency: "USD", destinationAmount: 100 }));
    if (result.kind !== "candidate") throw new Error("expected candidate");
    const entry = materializeProjectedOperation(result.candidate, { costGyd: 240, saleGyd: 260 });
    expect(entry.amount).toBe(100);
  });

  // Deviation from the ported source (document-rates.ts decision 9/10): the
  // deposit-derived CUP path no longer converts a missing cupGlobalRate to
  // NaN to fall back silently. When the caller supplies no cupGlobalRate at
  // all for a CUP candidate with a GYD deposit, deriving the amount throws
  // instead of silently falling back to destinationAmount.
  it("throws when a GYD-deposit CUP candidate is materialized without cupGlobalRate", () => {
    const result = projectStructuredOperation(source({ sourceAmount: 5_000, sourceCurrency: "GYD" }));
    if (result.kind !== "candidate") throw new Error("expected candidate");
    expect(() =>
      materializeProjectedOperation(result.candidate, { costGyd: 240, cupRate: 975 }),
    ).toThrow();
  });
});
