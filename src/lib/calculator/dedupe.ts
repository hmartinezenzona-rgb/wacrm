/**
 * Prevents a completed operation from being counted twice (e.g. once from
 * a live sync and once from a manual backfill) once completed remittance
 * operations start feeding the calculator. Manual entries have no
 * operationId and are never touched. Input is not mutated.
 *
 * Policy per `operationId` (source-order independent — callers do not need
 * to pre-sort):
 *   1. If any entry for that operationId has `status: "completed"`, a
 *      completed entry always wins, even if a `verified_pending` entry for
 *      the same operationId appeared earlier in the input. A `pending`
 *      entry never survives once any `completed` sibling shows up, at any
 *      position.
 *   2. If more than one entry is `completed`, the first `completed`
 *      occurrence (by input order) wins.
 *   3. If none are `completed`, the first `verified_pending` occurrence
 *      (by input order) wins.
 * The winning entry is emitted at the input position of the first
 * occurrence of its operationId, so relative ordering against other
 * operationIds/manual entries stays stable regardless of which status wins.
 */
import type { CalculatorEntry } from "./types";

export function dedupeCompletedOperationEntries(
  entries: CalculatorEntry[],
): CalculatorEntry[] {
  const result: CalculatorEntry[] = [];
  const winnerIndexByOperationId = new Map<string, number>();

  for (const entry of entries) {
    if (entry.source !== "completed_operation" || !entry.operationId) {
      result.push(entry);
      continue;
    }

    const operationId = entry.operationId;
    const existingIndex = winnerIndexByOperationId.get(operationId);

    if (existingIndex === undefined) {
      winnerIndexByOperationId.set(operationId, result.length);
      result.push(entry);
      continue;
    }

    const existing = result[existingIndex];
    if (entry.status === "completed" && existing.status !== "completed") {
      result[existingIndex] = entry;
    }
  }

  return result;
}
