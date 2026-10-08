/**
 * Money tones — the fixed colour meaning of a money figure on screen.
 *
 *   profit  green  positive "retorno"      loss  red    negative "retorno"
 *   out     amber  money out ("invertido") in    blue   money in ("facturado")
 *
 * The colours live in globals.css as --money-* tokens, independent of the accent theme. Colour never carries the
 * meaning alone: a profit total also gets an explicit sign (signedMoney) and an icon.
 *
 * Class names are written out in full so Tailwind can see them.
 */

export type MoneyTone = "profit" | "loss" | "out" | "in" | "neutral";

/** Text colour of a figure; neutral keeps the surrounding foreground. */
export const moneyTextClass: Record<MoneyTone, string> = {
  profit: "text-money-profit",
  loss: "text-money-loss",
  out: "text-money-out",
  in: "text-money-in",
  neutral: "",
};

/** 3px accent stripe on the left edge of a totals card. Inset shadow: it adds no width or height. */
export const moneyStripeClass: Record<MoneyTone, string> = {
  profit: "shadow-[inset_3px_0_0_var(--money-profit)]",
  loss: "shadow-[inset_3px_0_0_var(--money-loss)]",
  out: "shadow-[inset_3px_0_0_var(--money-out)]",
  in: "shadow-[inset_3px_0_0_var(--money-in)]",
  neutral: "",
};

/** Money figures are shown to the cent, so the sign is judged on the cents that will be printed. */
function cents(value: number): number {
  return Math.round(value * 100);
}

/** Profit when above zero, loss when below, neutral for zero, a missing figure or less than half a cent. */
export function profitTone(value: number | null | undefined): MoneyTone {
  if (value === null || value === undefined) return "neutral";
  const c = cents(value);
  if (c > 0) return "profit";
  if (c < 0) return "loss";
  return "neutral";
}

/** "+1 157 712,40" / "−2 500,00" (U+2212) / "0,00". `format` renders an unsigned magnitude. */
export function signedMoney(value: number, format: (magnitude: number) => string): string {
  const c = cents(value);
  if (c > 0) return `+${format(value)}`;
  if (c < 0) return `−${format(Math.abs(value))}`;
  return format(0);
}

/** What a totals figure stands for: money in (facturado), money out (invertido) or the result (retorno). */
export type TotalKind = "in" | "out" | "result";

/** Facturado is always "in", invertido always "out"; only the result changes colour with its sign. */
export function totalTone(kind: TotalKind, value: number): MoneyTone {
  if (kind === "in") return "in";
  if (kind === "out") return "out";
  return profitTone(value);
}

/** Props for a table cell whose text carries a tone; `base` keeps the cell's own classes. A neutral cell is left as it was. */
export function moneyCellProps(tone: MoneyTone, base = ""): { "data-tone"?: MoneyTone; className?: string } {
  const className = [base, moneyTextClass[tone]].filter(Boolean).join(" ");
  return {
    ...(tone === "neutral" ? {} : { "data-tone": tone }),
    ...(className ? { className } : {}),
  };
}
