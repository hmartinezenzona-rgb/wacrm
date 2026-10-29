// How the Finanzas screens write a figure: comma thousands, dot decimals ("35,609", "239.5"), the way the owner reads
// them in the mockups. Display only; the older money format (src/lib/format-number.ts) is untouched.

const FORMATTERS = new Map<number, Intl.NumberFormat>();

/** A number with comma thousands and at most `maxFraction` dot decimals (none by default). */
export function num(value: number, maxFraction = 0): string {
  let format = FORMATTERS.get(maxFraction);
  if (!format) {
    format = new Intl.NumberFormat("en-US", { useGrouping: true, maximumFractionDigits: maxFraction });
    FORMATTERS.set(maxFraction, format);
  }
  return format.format(value);
}

/** "10.4 %": one decimal at most. */
export function pctText(value: number): string {
  return `${num(value, 1)} %`;
}
