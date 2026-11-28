// Display and input helpers of the USD card inventory (Clásica / Tropical). Pure: no I/O.
import { formatNumber } from "@/lib/format-number";
import { parseCupNumber } from "@/lib/cup-inventory/format";

export { parseCupNumber as parseUsdNumber } from "@/lib/cup-inventory/format";

/** USD (or USDT) amount as the rest of the app writes figures; decimals only when there are some. */
export function formatUsd(value: number): string {
  return formatNumber(value, { maximumFractionDigits: 2 });
}

/**
 * Discount the owner got on a lot, derived from `usd_per_usdt` (USD received per USDT paid): 1.05 -> "5%", 1.00 -> "1x1".
 * A lot that cost more than its face value reads as a negative percentage.
 */
export function discountLabel(usdPerUsdt: number): string {
  const percent = (usdPerUsdt - 1) * 100;
  if (Math.abs(percent) < 0.05) return "1x1";
  return `${Number(percent.toFixed(1))}%`;
}

/**
 * Reads the discount typed by the owner: "5", "5%", "5,5" or "1x1" (= 0). Returns null unless it is a percentage from 0 up to
 * (excluding) 100.
 */
export function parsePercent(text: string): number | null {
  const cleaned = text.replace(/\s/g, "").replace(/%$/, "");
  if (/^1x1$/i.test(cleaned)) return 0;
  const value = parseCupNumber(cleaned, { allowZero: true });
  return value !== null && value < 100 ? value : null;
}

/** USDT to pay for `amountUsd` at a discount of `percent`: 500 USD at 5% -> 476.19 (rounded to cents). */
export function discountToUsdtPaid(amountUsd: number, percent: number): number {
  return Math.round((amountUsd / usdPerUsdtFromDiscount(percent)) * 100) / 100;
}

/** USD received per USDT paid at a discount of `percent`. */
export function usdPerUsdtFromDiscount(percent: number): number {
  return 1 + percent / 100;
}
