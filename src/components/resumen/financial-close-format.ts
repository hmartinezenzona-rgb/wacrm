import type { CloseEntry } from "@/lib/financial-close/read-model";
import { formatNumber } from "@/lib/format-number";

const TWO_DECIMALS = { maximumFractionDigits: 2 };
/** A rate is shown with every digit it has, only the separators change. */
const AS_IS = { maximumFractionDigits: 20 };
const rate = (n: number) => formatNumber(n, AS_IS);

/** Ledger money is always GYD (the business's settlement currency). */
export function fmtGyd(value: number | null | undefined): string {
  if (value === null || value === undefined) return "—";
  return `${formatNumber(value, TWO_DECIMALS)} GYD`;
}

export function fmtAmount(value: number, currency: string): string {
  return `${formatNumber(value, TWO_DECIMALS)} ${currency}`;
}

/** Margin as a percentage with one decimal, or null when nothing was billed. */
export function marginPct(facturado: number, retorno: number): string | null {
  if (!facturado) return null;
  return ((retorno / facturado) * 100).toFixed(1);
}

export { guyanaTime } from "@/lib/financial-close/periods";

/** The frozen rate the ledger used, so a row can be audited by hand. */
export function rateLabel(entry: CloseEntry): string {
  if (entry.cupRate !== null) return `CUP ${rate(entry.cupRate)}`;
  // The ledger snapshots the sale rate used in usdtSellGyd; for cash that is the cash rate.
  if (entry.service === "EFECTIVO" && entry.usdtSellGyd !== null) {
    return `EFECTIVO ${entry.usdtBuyGyd === null ? "?" : rate(entry.usdtBuyGyd)}/${rate(entry.usdtSellGyd)}`;
  }
  if (entry.usdtSellGyd !== null) return `USDT ${entry.usdtBuyGyd === null ? "?" : rate(entry.usdtBuyGyd)}/${rate(entry.usdtSellGyd)}`;
  return "—";
}

export function shortId(id: string | null): string {
  return id ? id.slice(0, 8) : "—";
}
