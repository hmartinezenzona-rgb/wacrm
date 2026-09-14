/**
 * Pure formula engine — one function per service, transcribed from
 * `procesarTexto()` in the owner's reference calculator
 * (`CALCULADORA OSMANY.txt`). No DOM, no parsing of the "• Cliente 50k CUP
 * (235/980)" shorthand: callers hand in already-parsed numeric fields.
 *
 * Deliberate deviation from the reference: the HTML falls back to `|| 0`
 * (or `|| 980` for CUP's tasaCupUsdt) when a rate is missing, which turns
 * a typo into a silent, wrong total. This engine throws
 * CalculatorValidationError instead — every entry (manual or completed
 * operation) is expected to carry its own real snapshot rates.
 */
import { CalculatorValidationError } from "./errors";
import type {
  CalculatorEntryFinancialInput,
  CalculatorEntryFinancials,
} from "./types";

function requireFiniteNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new CalculatorValidationError(
      `${field} must be a finite number`,
      field,
    );
  }
  return value;
}

function requireNonZero(value: number, field: string): number {
  if (value === 0) {
    throw new CalculatorValidationError(`${field} must not be zero`, field);
  }
  return value;
}

function finalize(
  facturadoGyd: number,
  invertidoGyd: number,
): CalculatorEntryFinancials {
  return { facturadoGyd, invertidoGyd, retornoGyd: facturadoGyd - invertidoGyd };
}

/**
 * Compute facturadoGyd/invertidoGyd/retornoGyd for one entry's financial
 * fields. Pure: no id/date/source/status involved, so it can be reused by
 * both manual and completed-operation normalization, and re-run later on
 * a stored snapshot without needing the rest of the entry.
 */
export function calculateEntry(
  input: CalculatorEntryFinancialInput,
): CalculatorEntryFinancials {
  const amount = requireFiniteNumber(input.amount, "amount");
  if (amount <= 0) {
    throw new CalculatorValidationError(
      "amount must be greater than zero",
      "amount",
    );
  }

  switch (input.service) {
    case "DIRECTO": {
      return finalize(amount, 0);
    }

    case "CUP": {
      // facturado uses cupGlobalRate (tarifaCupGlobal, the reference
      // calculator's single global CUP rate input); invertido uses cupRate
      // (tasaCupUsdt, the per-entry detail rate) and costGyd. These are two
      // distinct rates from two distinct UI inputs — never conflate them.
      const costGyd = requireFiniteNumber(input.costGyd, "costGyd");
      const cupRate = requireNonZero(
        requireFiniteNumber(input.cupRate, "cupRate"),
        "cupRate",
      );
      const cupGlobalRate = requireNonZero(
        requireFiniteNumber(input.cupGlobalRate, "cupGlobalRate"),
        "cupGlobalRate",
      );
      const facturadoGyd = amount / cupGlobalRate;
      const invertidoGyd = (amount / cupRate) * costGyd;
      return finalize(facturadoGyd, invertidoGyd);
    }

    case "ZELLE":
    case "MLC":
    case "CLASICA":
    case "TROPICAL": {
      const costGyd = requireFiniteNumber(input.costGyd, "costGyd");
      const saleGyd = requireFiniteNumber(input.saleGyd, "saleGyd");
      const discountPct =
        input.discountPct === undefined
          ? 0
          : requireFiniteNumber(input.discountPct, "discountPct");
      if (discountPct < 0) {
        throw new CalculatorValidationError(
          "discountPct must not be negative",
          "discountPct",
        );
      }
      const fraction = discountPct / 100;
      const adjustedAmount = fraction > 0 ? amount / (1 + fraction) : amount;
      const invertidoGyd = adjustedAmount * costGyd;
      const facturadoGyd = amount * saleGyd;
      return finalize(facturadoGyd, invertidoGyd);
    }

    case "USDT": {
      const costGyd = requireFiniteNumber(input.costGyd, "costGyd");
      const saleGyd = requireFiniteNumber(input.saleGyd, "saleGyd");
      const invertidoGyd = amount * costGyd;
      const facturadoGyd = amount * saleGyd;
      return finalize(facturadoGyd, invertidoGyd);
    }

    case "RECARGA":
    case "SALDO_MOVIL": {
      const costGyd = requireFiniteNumber(input.costGyd, "costGyd");
      const saleGyd = requireFiniteNumber(input.saleGyd, "saleGyd");
      const cupRate = requireFiniteNumber(input.cupRate, "cupRate");
      const invertidoGyd = amount * costGyd * cupRate;
      const facturadoGyd = amount * saleGyd;
      return finalize(facturadoGyd, invertidoGyd);
    }

    default: {
      // Exhaustiveness guard: TS narrows `input.service` to `never` above
      // when every CalculatorServiceType is handled, so this only fires
      // for a value that bypassed the type system (e.g. JSON from a form).
      const service = input.service as string;
      throw new CalculatorValidationError(
        `Unsupported service: ${service}`,
        "service",
      );
    }
  }
}
