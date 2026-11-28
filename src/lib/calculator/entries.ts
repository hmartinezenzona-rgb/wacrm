/**
 * Normalizers — turn a draft (manual input, or a future completed-operation
 * projection) into a full CalculatorEntry: identity fields validated,
 * financials computed via `calculateEntry`. Neither function persists
 * anything; the calculator core is domain-only.
 */
import { calculateEntry } from "./formulas";
import { CalculatorValidationError } from "./errors";
import type {
  CalculatorEntry,
  CompletedOperationCalculatorEntryDraft,
  ManualCalculatorEntryDraft,
} from "./types";

function requireNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new CalculatorValidationError(
      `${field} must be a non-empty string`,
      field,
    );
  }
  return value;
}

/**
 * Manual entries always count immediately: they are always `source:
 * "manual"` and `status: "completed"` — there is no manual equivalent of
 * verified-but-not-completed.
 */
export function normalizeManualEntry(
  draft: ManualCalculatorEntryDraft,
): CalculatorEntry {
  requireNonEmptyString(draft.id, "id");
  requireNonEmptyString(draft.date, "date");
  requireNonEmptyString(draft.amountCurrency, "amountCurrency");

  const financials = calculateEntry(draft);

  return {
    ...draft,
    source: "manual",
    status: "completed",
    ...financials,
  };
}

/**
 * A completed-operation entry may be `completed` or `verified_pending`.
 * `operationId` is required so `dedupeCompletedOperationEntries` can
 * identify duplicates once real operations are wired in.
 */
export function normalizeCompletedOperationEntry(
  draft: CompletedOperationCalculatorEntryDraft,
): CalculatorEntry {
  requireNonEmptyString(draft.id, "id");
  requireNonEmptyString(draft.date, "date");
  requireNonEmptyString(draft.amountCurrency, "amountCurrency");
  requireNonEmptyString(draft.operationId, "operationId");
  if (draft.status !== "completed" && draft.status !== "verified_pending") {
    throw new CalculatorValidationError(
      "status must be 'completed' or 'verified_pending'",
      "status",
    );
  }

  const financials = calculateEntry(draft);

  return {
    ...draft,
    source: "completed_operation",
    ...financials,
  };
}
