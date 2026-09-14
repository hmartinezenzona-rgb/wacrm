import { describe, expect, it } from "vitest";
import { dedupeCompletedOperationEntries } from "./dedupe";
import { normalizeCompletedOperationEntry, normalizeManualEntry } from "./entries";
import type { CalculatorEntry } from "./types";

function operationEntry(
  id: string,
  operationId: string,
  status: "completed" | "verified_pending",
): CalculatorEntry {
  return normalizeCompletedOperationEntry({
    id,
    date: "2026-01-05",
    amountCurrency: "GYD",
    operationId,
    status,
    service: "DIRECTO",
    amount: 1_000,
  });
}

function manualEntry(id: string): CalculatorEntry {
  return normalizeManualEntry({
    id,
    date: "2026-01-05",
    amountCurrency: "GYD",
    service: "DIRECTO",
    amount: 1_000,
  });
}

describe("dedupeCompletedOperationEntries", () => {
  it("removes duplicate completed entries sharing the same operationId, keeping the first completed occurrence", () => {
    const first = operationEntry("entry-a", "op-1", "completed");
    const duplicate = operationEntry("entry-b", "op-1", "completed");

    const result = dedupeCompletedOperationEntries([first, duplicate]);

    expect(result).toEqual([first]);
  });

  it("removes duplicate pending entries sharing the same operationId, keeping the first pending occurrence", () => {
    const first = operationEntry("entry-a", "op-1", "verified_pending");
    const duplicate = operationEntry("entry-b", "op-1", "verified_pending");

    const result = dedupeCompletedOperationEntries([first, duplicate]);

    expect(result).toEqual([first]);
  });

  it("never removes manual entries, which have no operationId", () => {
    const manualA = manualEntry("manual-a");
    const manualB = manualEntry("manual-b");

    const result = dedupeCompletedOperationEntries([manualA, manualB]);

    expect(result).toEqual([manualA, manualB]);
  });

  it("does not remove manual entries even when they share an id-like value with an operation entry", () => {
    const manualA = manualEntry("shared-id");
    const manualB = manualEntry("shared-id");

    const result = dedupeCompletedOperationEntries([manualA, manualB]);

    expect(result).toEqual([manualA, manualB]);
  });

  it("does not mutate the original array", () => {
    const first = operationEntry("entry-a", "op-1", "completed");
    const duplicate = operationEntry("entry-b", "op-1", "completed");
    const input = [first, duplicate];
    const inputSnapshot = [...input];

    dedupeCompletedOperationEntries(input);

    expect(input).toEqual(inputSnapshot);
    expect(input).toHaveLength(2);
  });

  // Documented policy (see dedupe.ts): completed always wins over
  // verified_pending, regardless of input order.
  it("policy: a pending entry listed before its completed counterpart is dropped in favor of completed", () => {
    const pendingFirst = operationEntry("entry-pending", "op-1", "verified_pending");
    const completedSecond = operationEntry("entry-completed", "op-1", "completed");

    const result = dedupeCompletedOperationEntries([pendingFirst, completedSecond]);

    expect(result).toEqual([completedSecond]);
  });

  it("policy: when the completed entry is listed first, it is the one kept", () => {
    const completedFirst = operationEntry("entry-completed", "op-1", "completed");
    const pendingSecond = operationEntry("entry-pending", "op-1", "verified_pending");

    const result = dedupeCompletedOperationEntries([completedFirst, pendingSecond]);

    expect(result).toEqual([completedFirst]);
  });

  it("policy: with multiple completed entries, the first completed occurrence wins even if a pending entry sits between them", () => {
    const completedFirst = operationEntry("entry-completed-1", "op-1", "completed");
    const pendingMiddle = operationEntry("entry-pending", "op-1", "verified_pending");
    const completedSecond = operationEntry("entry-completed-2", "op-1", "completed");

    const result = dedupeCompletedOperationEntries([
      completedFirst,
      pendingMiddle,
      completedSecond,
    ]);

    expect(result).toEqual([completedFirst]);
  });

  it("policy: a pending entry followed by two completed entries keeps the first completed occurrence", () => {
    const pendingFirst = operationEntry("entry-pending", "op-1", "verified_pending");
    const completedFirst = operationEntry("entry-completed-1", "op-1", "completed");
    const completedSecond = operationEntry("entry-completed-2", "op-1", "completed");

    const result = dedupeCompletedOperationEntries([
      pendingFirst,
      completedFirst,
      completedSecond,
    ]);

    expect(result).toEqual([completedFirst]);
  });

  it("preserves the winner at the position of the operationId's first occurrence relative to other entries", () => {
    const manualA = manualEntry("manual-a");
    const pendingFirst = operationEntry("entry-pending", "op-1", "verified_pending");
    const manualB = manualEntry("manual-b");
    const completedSecond = operationEntry("entry-completed", "op-1", "completed");

    const result = dedupeCompletedOperationEntries([
      manualA,
      pendingFirst,
      manualB,
      completedSecond,
    ]);

    expect(result).toEqual([manualA, completedSecond, manualB]);
  });
});
