/**
 * Number display — single source of truth for how a figure is written on screen.
 *
 * The BIPM and the RAE recommend grouping digits in threes with a blank space (never commas or dots) and writing the
 * decimal with a comma: 1 157 712,40. The blank is U+202F (narrow no-break space) so a figure never wraps mid-number.
 *
 * Deterministic on purpose: the number is formatted with en-US and only its separators are swapped. The `es`
 * locales are NOT used because es-ES leaves four-digit numbers ungrouped ("5000") and ICU versions disagree on the
 * space character, so Node, jsdom and each browser would not print the same string.
 *
 * Display only: parsers of typed text keep their own grammar, and anything sent to a customer or a machine is not
 * formatted here.
 */

/** Group separator: narrow no-break space. */
export const GROUP_SEPARATOR = " ";
/** Decimal separator. */
export const DECIMAL_SEPARATOR = ",";

export interface FormatNumberOptions {
  minimumFractionDigits?: number;
  maximumFractionDigits?: number;
}

/** Swaps the separators of an en-US formatted string ("1,234.5" -> "1 234,5"); any other character is untouched. */
export function localizeSeparators(formatted: string): string {
  return formatted.replace(/[,.]/g, (char) => (char === "," ? GROUP_SEPARATOR : DECIMAL_SEPARATOR));
}

/** Formats a number as "1 157 712,40". Always groups in threes, four-digit numbers included. */
export function formatNumber(value: number, options: FormatNumberOptions = {}): string {
  return localizeSeparators(
    new Intl.NumberFormat("en-US", { ...options, useGrouping: true }).format(value),
  );
}

/**
 * Formats with an arbitrary (typically currency-styled, en-US) formatter and swaps only the group and decimal parts,
 * so a currency symbol or code is never touched.
 */
export function formatNumberParts(formatter: Intl.NumberFormat, value: number): string {
  return formatter
    .formatToParts(value)
    .map((part) => {
      if (part.type === "group") return GROUP_SEPARATOR;
      if (part.type === "decimal") return DECIMAL_SEPARATOR;
      return part.value;
    })
    .join("");
}
