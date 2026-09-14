// Barrel for the calculator pure core. Deliberately excludes `server.ts`
// (Core-coupled to `remittance_verification_runs`, out of scope for this
// change per the design's exclusion list) — nothing in this slice ports it.
export type {
  CalculatorEntry,
  CalculatorEntryDraft,
  CalculatorEntryFinancialInput,
  CalculatorEntryFinancials,
  CalculatorEntryRates,
  CalculatorEntrySource,
  CalculatorEntryStatus,
  CalculatorServiceType,
  CalculatorTotals,
  CompletedOperationCalculatorEntryDraft,
  ManualCalculatorEntryDraft,
} from "./types";

export { CalculatorValidationError } from "./errors";
export { calculateEntry } from "./formulas";
export {
  normalizeCompletedOperationEntry,
  normalizeManualEntry,
} from "./entries";
export { calculateTotals, filterIncludedEntries } from "./totals";
export { dedupeCompletedOperationEntries } from "./dedupe";
export {
  materializeProjectedOperation,
  projectStructuredOperation,
} from "./projection";
export type {
  CalculatorProjection,
  CalculatorProjectionCandidate,
  CalculatorProjectionRejection,
  StructuredRemittanceCalculatorSource,
} from "./projection";
export {
  computeAutoCompletionSnapshot,
  computeAutoCompletionSnapshotFromDeposit,
  deriveAmountFromDeposit,
  missingDocumentRates,
  rateInputForService,
} from "./document-rates";
export type {
  CalculatorAutoCompletionService,
  CalculatorDocumentRates,
} from "./document-rates";
export {
  parseMonto,
  parseShorthandLine,
} from "./shorthand-parser";
export type {
  ShorthandDayHeader,
  ShorthandEntryDraft,
  ShorthandEntryResult,
  ShorthandParseError,
  ShorthandParseResult,
} from "./shorthand-parser";
