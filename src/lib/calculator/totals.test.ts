import { describe, expect, it } from "vitest";
import { normalizeCompletedOperationEntry, normalizeManualEntry } from "./entries";
import { calculateTotals, filterIncludedEntries } from "./totals";
import type { CalculatorEntry } from "./types";

function manualUsdt(id: string, amount: number): CalculatorEntry {
  return normalizeManualEntry({
    id,
    date: "2026-01-05",
    amountCurrency: "GYD",
    service: "USDT",
    amount,
    costGyd: 235,
    saleGyd: 260,
  });
}

function completedOperationDirecto(
  id: string,
  operationId: string,
  status: "completed" | "verified_pending",
  amount: number,
): CalculatorEntry {
  return normalizeCompletedOperationEntry({
    id,
    date: "2026-01-05",
    amountCurrency: "GYD",
    operationId,
    status,
    service: "DIRECTO",
    amount,
  });
}

describe("filterIncludedEntries", () => {
  it("keeps only status: completed entries", () => {
    const completed = manualUsdt("m1", 1_000);
    const pending = completedOperationDirecto("op-entry-1", "op-1", "verified_pending", 5_000);

    expect(filterIncludedEntries([completed, pending])).toEqual([completed]);
  });
});

describe("calculateTotals", () => {
  it("sums a completed manual entry and a completed_operation entry together", () => {
    const manual = manualUsdt("m1", 1_000); // facturado 260_000, invertido 235_000
    const operation = completedOperationDirecto("op-entry-1", "op-1", "completed", 5_000); // facturado 5_000, invertido 0

    const totals = calculateTotals([manual, operation]);

    expect(totals.count).toBe(2);
    expect(totals.facturadoGyd).toBeCloseTo(265_000, 6);
    expect(totals.invertidoGyd).toBeCloseTo(235_000, 6);
    expect(totals.retornoGyd).toBeCloseTo(30_000, 6);
  });

  it("a verified_pending entry appears as an entry but never sums nor increases count", () => {
    const manual = manualUsdt("m1", 1_000);
    const pending = completedOperationDirecto("op-entry-2", "op-2", "verified_pending", 999_999);

    const totals = calculateTotals([manual, pending]);

    expect(totals.count).toBe(1);
    expect(totals.facturadoGyd).toBeCloseTo(260_000, 6);
    expect(totals.invertidoGyd).toBeCloseTo(235_000, 6);
    expect(totals.retornoGyd).toBeCloseTo(25_000, 6);
  });

  it("sums across a mix of services", () => {
    const usdt = manualUsdt("m1", 1_000); // facturado 260_000, invertido 235_000
    const directo = completedOperationDirecto("op-entry-3", "op-3", "completed", 5_000); // facturado 5_000, invertido 0
    const cup = normalizeManualEntry({
      id: "m2",
      date: "2026-01-05",
      amountCurrency: "CUP",
      service: "CUP",
      amount: 50_000,
      costGyd: 235,
      cupRate: 980,
      cupGlobalRate: 3,
    }); // facturado 16_666.666666666668, invertido 11_989.795918367348

    const totals = calculateTotals([usdt, directo, cup]);

    expect(totals.count).toBe(3);
    expect(totals.facturadoGyd).toBeCloseTo(260_000 + 5_000 + 16_666.666666666668, 6);
    expect(totals.invertidoGyd).toBeCloseTo(235_000 + 0 + 11_989.795918367348, 6);
    expect(totals.retornoGyd).toBeCloseTo(
      (260_000 - 235_000) + (5_000 - 0) + (16_666.666666666668 - 11_989.795918367348),
      6,
    );
  });

  it("never counts an operationId twice, even when a pending duplicate is listed before its completed counterpart", () => {
    const pendingFirst = completedOperationDirecto("op-entry-1", "op-1", "verified_pending", 5_000);
    const completedSecond = completedOperationDirecto("op-entry-2", "op-1", "completed", 5_000);

    const totals = calculateTotals([pendingFirst, completedSecond]);

    expect(totals.count).toBe(1);
    expect(totals.facturadoGyd).toBeCloseTo(5_000, 6);
    expect(totals.invertidoGyd).toBeCloseTo(0, 6);
    expect(totals.retornoGyd).toBeCloseTo(5_000, 6);
  });

  it("never counts an operationId twice when duplicate completed entries are passed in", () => {
    const first = completedOperationDirecto("op-entry-1", "op-1", "completed", 5_000);
    const duplicate = completedOperationDirecto("op-entry-2", "op-1", "completed", 5_000);

    const totals = calculateTotals([first, duplicate]);

    expect(totals.count).toBe(1);
    expect(totals.facturadoGyd).toBeCloseTo(5_000, 6);
  });

  it("does not mutate the input array", () => {
    const pendingFirst = completedOperationDirecto("op-entry-1", "op-1", "verified_pending", 5_000);
    const completedSecond = completedOperationDirecto("op-entry-2", "op-1", "completed", 5_000);
    const input = [pendingFirst, completedSecond];
    const inputSnapshot = [...input];

    calculateTotals(input);

    expect(input).toEqual(inputSnapshot);
    expect(input).toHaveLength(2);
  });
});
