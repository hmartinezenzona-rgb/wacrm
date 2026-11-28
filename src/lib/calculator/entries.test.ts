import { describe, expect, it } from "vitest";
import { normalizeCompletedOperationEntry, normalizeManualEntry } from "./entries";
import { CalculatorValidationError } from "./errors";
import type {
  CompletedOperationCalculatorEntryDraft,
  ManualCalculatorEntryDraft,
} from "./types";

function baseManualDraft(
  overrides: Partial<ManualCalculatorEntryDraft> = {},
): ManualCalculatorEntryDraft {
  return {
    id: "manual-1",
    date: "2026-01-05",
    amountCurrency: "GYD",
    service: "USDT",
    amount: 1_000,
    costGyd: 235,
    saleGyd: 260,
    ...overrides,
  };
}

function baseCompletedDraft(
  overrides: Partial<CompletedOperationCalculatorEntryDraft> = {},
): CompletedOperationCalculatorEntryDraft {
  return {
    id: "op-entry-1",
    date: "2026-01-05",
    amountCurrency: "GYD",
    operationId: "op-1",
    status: "completed",
    service: "USDT",
    amount: 1_000,
    costGyd: 235,
    saleGyd: 260,
    ...overrides,
  };
}

describe("normalizeManualEntry", () => {
  it("always assigns source: manual and status: completed", () => {
    const entry = normalizeManualEntry(baseManualDraft());
    expect(entry.source).toBe("manual");
    expect(entry.status).toBe("completed");
  });

  it("computes financials via calculateEntry and preserves identity fields", () => {
    const entry = normalizeManualEntry(baseManualDraft({ id: "manual-42" }));
    expect(entry.id).toBe("manual-42");
    expect(entry.facturadoGyd).toBeCloseTo(260_000, 6);
    expect(entry.invertidoGyd).toBeCloseTo(235_000, 6);
    expect(entry.retornoGyd).toBeCloseTo(25_000, 6);
  });

  it("rejects a missing id", () => {
    expect(() => normalizeManualEntry(baseManualDraft({ id: "" }))).toThrow(
      CalculatorValidationError,
    );
  });

  it("rejects a missing date", () => {
    expect(() => normalizeManualEntry(baseManualDraft({ date: "" }))).toThrow(
      CalculatorValidationError,
    );
  });

  it("rejects a blank amountCurrency", () => {
    expect(() =>
      normalizeManualEntry(baseManualDraft({ amountCurrency: "   " })),
    ).toThrow(CalculatorValidationError);
  });

  it("propagates CalculatorValidationError for invalid rates from calculateEntry", () => {
    expect(() =>
      normalizeManualEntry(baseManualDraft({ costGyd: undefined })),
    ).toThrow(CalculatorValidationError);
  });
});

describe("normalizeCompletedOperationEntry", () => {
  it("preserves operationId and status", () => {
    const entry = normalizeCompletedOperationEntry(
      baseCompletedDraft({ operationId: "op-99", status: "verified_pending" }),
    );
    expect(entry.operationId).toBe("op-99");
    expect(entry.status).toBe("verified_pending");
    expect(entry.source).toBe("completed_operation");
  });

  it("computes financials via calculateEntry", () => {
    const entry = normalizeCompletedOperationEntry(baseCompletedDraft());
    expect(entry.facturadoGyd).toBeCloseTo(260_000, 6);
    expect(entry.invertidoGyd).toBeCloseTo(235_000, 6);
  });

  it("rejects a missing operationId", () => {
    expect(() =>
      normalizeCompletedOperationEntry(baseCompletedDraft({ operationId: "" })),
    ).toThrow(CalculatorValidationError);
  });

  it("rejects an invalid status", () => {
    expect(() =>
      normalizeCompletedOperationEntry(
        // @ts-expect-error deliberately invalid status
        baseCompletedDraft({ status: "pending_review" }),
      ),
    ).toThrow(CalculatorValidationError);
  });

  it("propagates CalculatorValidationError for invalid rates from calculateEntry", () => {
    expect(() =>
      normalizeCompletedOperationEntry(baseCompletedDraft({ saleGyd: undefined })),
    ).toThrow(CalculatorValidationError);
  });
});

describe("entry snapshot immutability against external rate changes", () => {
  it("an already-calculated entry keeps its own values even if an external global rate changes later", () => {
    let currentCupGlobalRate = 3.0;

    const entry = normalizeManualEntry({
      id: "cup-1",
      date: "2026-01-05",
      amountCurrency: "CUP",
      service: "CUP",
      amount: 50_000,
      costGyd: 235,
      cupRate: 980,
      cupGlobalRate: currentCupGlobalRate,
    });

    const facturadoAtCreation = entry.facturadoGyd;
    expect(facturadoAtCreation).toBeCloseTo(16_666.666666666668, 6);

    // The global rate changes afterwards (e.g. the owner edits the
    // reference HTML's "Tarifa CUP Global" input for future entries); the
    // already-calculated entry must not be affected because it stores its
    // own snapshot value rather than a live reference to the external one.
    currentCupGlobalRate = 5.0;

    expect(entry.facturadoGyd).toBe(facturadoAtCreation);
    expect(entry.facturadoGyd).not.toBeCloseTo(50_000 / currentCupGlobalRate, 6);
  });
});
