// Display helpers for the reseller totals. Money uses the Finanzas figure style
// (comma thousands, no decimals) so the new tab reads like the rest of the page.

import { num } from "@/lib/finanzas/number-format";

/** "15,000 GYD" / "-2,000 GYD": the panel's money format. */
export function formatGyd(value: number): string {
  return `${num(value)} GYD`;
}

/** "+3,000 GYD" / "−2,000 GYD" / "0 GYD": a signed adjustment. */
export function formatSignedGyd(value: number): string {
  if (value === 0) return formatGyd(0);
  return `${value > 0 ? "+" : "−"}${formatGyd(Math.abs(value))}`;
}

/** A timestamptz as a short local date (Guyana time, like the rest of Finanzas). */
export function formatResellerDate(iso: string, locale: string): string {
  return new Intl.DateTimeFormat(locale, {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "America/Guyana",
  }).format(new Date(iso));
}
