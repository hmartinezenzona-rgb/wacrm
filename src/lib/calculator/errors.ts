/** Thrown by calculator validation. Always explicit — the engine never
 * substitutes NaN/Infinity or a silent default for a missing/invalid
 * numeric input. */
export class CalculatorValidationError extends Error {
  readonly field: string;

  constructor(message: string, field: string) {
    super(message);
    this.name = "CalculatorValidationError";
    this.field = field;
  }
}
