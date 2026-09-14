/**
 * Parses the owner's single-line manual shorthand notation (e.g.
 * "• Onaisy 1 rec promo(23.1/6.2k/240)") into calculator entry input
 * fields. The parsing SEMANTICS — bullet stripping, day headers, the `k`
 * thousands multiplier, service abbreviations (incl. "REC" -> RECARGA),
 * direct services, and the parenthesized rate detail — are ported from the
 * reference `web-calculator.ts` (`parsearLinea`/`serviceFrom`/`parseMonto`).
 *
 * Deliberate deviation from that reference: `web-calculator.ts` silently
 * substitutes 0 for a missing/invalid numeric token (`parseFloat(x) || 0`,
 * or `|| 980` for CUP's cupRate) and falls through to a "DESCONOCIDO"
 * service instead of failing. This module never does that — a syntactically
 * unrecognized line, an unrecognized service abbreviation, or an
 * unparsable numeric token in a position that WAS supplied all produce an
 * explicit `{ kind: "error" }` result instead of a fabricated entry. A rate
 * position that is simply absent from the shorthand (e.g. CUP written with
 * only one detail value) is left `undefined` on the draft, so the formula
 * engine's own validation (`calculateEntry`) raises the final
 * CalculatorValidationError naming that field — still never a silent 0.
 *
 * This module only parses syntax. It does not compute financials or carry
 * `cupGlobalRate` (a global rate, never present in the per-line detail);
 * callers combine the returned draft with `id`/`date`/`cupGlobalRate` and
 * hand it to `normalizeManualEntry`.
 */
import type { CalculatorServiceType } from "./types";

export interface ShorthandEntryDraft {
  customerName: string;
  service: CalculatorServiceType;
  amount: number;
  amountRaw: string;
  discountPct?: number;
  costGyd?: number;
  saleGyd?: number;
  cupRate?: number;
  /** Free-form label for a DIRECTO service (e.g. the matched "visa"/"ext"
   * text), kept only for display — the formula engine ignores it
   * (facturado = amount, invertido = 0 for every DIRECTO entry). */
  directLabel?: string;
  day: string;
  raw: string;
}

export interface ShorthandDayHeader {
  kind: "day";
  day: string;
}

export interface ShorthandEntryResult {
  kind: "entry";
  draft: ShorthandEntryDraft;
}

export interface ShorthandParseError {
  kind: "error";
  message: string;
  raw: string;
}

export type ShorthandParseResult =
  | ShorthandDayHeader
  | ShorthandEntryResult
  | ShorthandParseError;

const DAY_PATTERN =
  /^(lunes|martes|miercoles|miércoles|jueves|viernes|sabado|sábado|domingo)/i;

const DIRECT_SERVICE_PATTERN = /(visa|ext|trabajo|estudiante|trad|combo|pasaje)/i;

const DIRECT_LINE_PATTERN =
  /^([A-Za-zÁ-ÿ\s]+?)\s+(.+?)\s+([\d.,]+[kK]?\s*(?:gyd)?)$/i;

const GENERAL_LINE_PATTERN =
  /^([A-Za-zÁ-ÿ\s]+?)\s+([\d.,]+[kK]?)\s*([A-Za-zÁ-ÿ\s]+?)(?:\s*\((.*?)\))?$/;

/** Parses one numeric shorthand token, honoring a trailing "k" (×1000) and
 * stripping a trailing "gyd" unit and thousands separators, exactly like
 * the reference calculator. Returns `null` — never 0 — when the token is
 * missing or not a finite number. */
export function parseMonto(raw: string | undefined): number | null {
  if (!raw) return null;
  const normalized = raw.toLowerCase().replace("gyd", "").trim();
  const numeric = normalized.endsWith("k")
    ? Number.parseFloat(normalized.slice(0, -1)) * 1000
    : Number.parseFloat(normalized.replace(/,/g, ""));
  return Number.isFinite(numeric) ? numeric : null;
}

function serviceFrom(typeRaw: string): CalculatorServiceType | null {
  const upper = typeRaw.toUpperCase();
  if (upper.includes("CUP")) return "CUP";
  if (upper.includes("ZELLE")) return "ZELLE";
  if (upper.includes("MLC")) return "MLC";
  if (upper.includes("TROPI")) return "TROPICAL";
  if (upper.includes("CLASICA") || upper.includes("CLÁSICA")) return "CLASICA";
  if (upper.includes("USDT") || upper.includes("USD")) return "USDT";
  if (upper.includes("SALDO") || upper.includes("MOVIL") || upper.includes("MÓVIL")) {
    return "SALDO_MOVIL";
  }
  if (upper.includes("REC")) return "RECARGA";
  return null;
}

/** Parses a required numeric rate token at `params[index]`: `undefined`
 * when that position was never supplied (so `calculateEntry` raises its
 * own "must be a finite number" error naming the field), or the sentinel
 * `"invalid"` when the position WAS supplied but is not a valid number (a
 * shorthand typo) — the caller turns that into an explicit parse error. */
function parseRequiredToken(
  params: string[],
  index: number,
): number | undefined | "invalid" {
  const token = params[index];
  if (token === undefined) return undefined;
  const value = Number.parseFloat(token.replace("%", ""));
  return Number.isFinite(value) ? value : "invalid";
}

export function parseShorthandLine(
  line: string,
  currentDay: string,
): ShorthandParseResult | null {
  const trimmed = line.replace(/^[•\-*]\s*/, "").trim();
  if (!trimmed) return null;

  if (DAY_PATTERN.test(trimmed)) {
    return { kind: "day", day: trimmed };
  }

  if (DIRECT_SERVICE_PATTERN.test(trimmed)) {
    const directMatch = trimmed.match(DIRECT_LINE_PATTERN);
    if (directMatch) {
      const amount = parseMonto(directMatch[3]);
      if (amount === null) {
        return { kind: "error", message: `Invalid amount: "${directMatch[3]}"`, raw: line };
      }
      return {
        kind: "entry",
        draft: {
          customerName: directMatch[1].trim(),
          service: "DIRECTO",
          amount,
          amountRaw: directMatch[3],
          directLabel: directMatch[2].trim().toUpperCase(),
          day: currentDay,
          raw: line,
        },
      };
    }
  }

  const match = trimmed.match(GENERAL_LINE_PATTERN);
  if (!match) {
    return { kind: "error", message: `Unrecognized shorthand line: "${line}"`, raw: line };
  }

  const service = serviceFrom(match[3] || "");
  if (!service) {
    return {
      kind: "error",
      message: `Unrecognized service abbreviation: "${(match[3] || "").trim()}"`,
      raw: line,
    };
  }

  const amount = parseMonto(match[2]);
  if (amount === null) {
    return { kind: "error", message: `Invalid amount: "${match[2]}"`, raw: line };
  }

  const detail = match[4] || "";
  const params = detail ? detail.split("/") : [];

  const draft: ShorthandEntryDraft = {
    customerName: match[1].trim(),
    service,
    amount,
    amountRaw: match[2],
    day: currentDay,
    raw: line,
  };

  switch (service) {
    case "CUP": {
      const costGyd = parseRequiredToken(params, 0);
      if (costGyd === "invalid") {
        return { kind: "error", message: `Invalid costGyd token: "${params[0]}"`, raw: line };
      }
      const cupRate = parseRequiredToken(params, 1);
      if (cupRate === "invalid") {
        return { kind: "error", message: `Invalid cupRate token: "${params[1]}"`, raw: line };
      }
      draft.costGyd = costGyd;
      draft.cupRate = cupRate;
      break;
    }
    case "ZELLE":
    case "MLC":
    case "CLASICA":
    case "TROPICAL": {
      let index = 0;
      if (params[0]?.includes("%")) {
        const discountPct = parseRequiredToken(params, 0);
        if (discountPct === "invalid") {
          return { kind: "error", message: `Invalid discount token: "${params[0]}"`, raw: line };
        }
        draft.discountPct = discountPct;
        index = 1;
      }
      const costGyd = parseRequiredToken(params, index);
      if (costGyd === "invalid") {
        return { kind: "error", message: `Invalid costGyd token: "${params[index]}"`, raw: line };
      }
      const saleGyd = parseRequiredToken(params, index + 1);
      if (saleGyd === "invalid") {
        return {
          kind: "error",
          message: `Invalid saleGyd token: "${params[index + 1]}"`,
          raw: line,
        };
      }
      draft.costGyd = costGyd;
      draft.saleGyd = saleGyd;
      break;
    }
    case "USDT": {
      const costGyd = parseRequiredToken(params, 0);
      if (costGyd === "invalid") {
        return { kind: "error", message: `Invalid costGyd token: "${params[0]}"`, raw: line };
      }
      const saleGyd = parseRequiredToken(params, 1);
      if (saleGyd === "invalid") {
        return { kind: "error", message: `Invalid saleGyd token: "${params[1]}"`, raw: line };
      }
      draft.costGyd = costGyd;
      draft.saleGyd = saleGyd;
      break;
    }
    case "RECARGA":
    case "SALDO_MOVIL": {
      const costGyd = parseRequiredToken(params, 0);
      if (costGyd === "invalid") {
        return { kind: "error", message: `Invalid costGyd token: "${params[0]}"`, raw: line };
      }
      // saleGyd honors the "k" multiplier (e.g. "6.2k" -> 6200), same as
      // the reference's ventaUnitGyd = parseMonto(params[1]).
      const saleGydToken = params[1];
      const saleGyd = saleGydToken === undefined ? undefined : parseMonto(saleGydToken);
      if (saleGydToken !== undefined && saleGyd === null) {
        return { kind: "error", message: `Invalid saleGyd token: "${saleGydToken}"`, raw: line };
      }
      const cupRate = parseRequiredToken(params, 2);
      if (cupRate === "invalid") {
        return { kind: "error", message: `Invalid cupRate token: "${params[2]}"`, raw: line };
      }
      draft.costGyd = costGyd;
      draft.saleGyd = saleGyd ?? undefined;
      draft.cupRate = cupRate;
      break;
    }
    case "DIRECTO":
      // Unreachable here: DIRECTO lines are handled by the direct-service
      // branch above, before the general pattern is even tried.
      break;
  }

  return { kind: "entry", draft };
}
