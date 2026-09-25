import { BUSINESS_TIME_ZONE } from "@/lib/financial-close/periods";
import type { CloseEntry } from "@/lib/financial-close/read-model";

/** Ledger money is always GYD (the business's settlement currency). */
export function fmtGyd(value: number | null | undefined): string {
  if (value === null || value === undefined) return "—";
  return `${value.toLocaleString("en-US", { maximumFractionDigits: 2 })} GYD`;
}

export function fmtAmount(value: number, currency: string): string {
  return `${value.toLocaleString("en-US", { maximumFractionDigits: 2 })} ${currency}`;
}

/** Margin as a percentage with one decimal, or null when nothing was billed. */
export function marginPct(facturado: number, retorno: number): string | null {
  if (!facturado) return null;
  return ((retorno / facturado) * 100).toFixed(1);
}

/** HH:mm of a completion in Guyana time — the clock the business lives on. */
export function guyanaTime(iso: string | null): string {
  if (!iso) return "—";
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: BUSINESS_TIME_ZONE,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(iso));
}

/** The frozen rate the ledger used, so a row can be audited by hand. */
export function rateLabel(entry: CloseEntry): string {
  if (entry.cupRate !== null) return `CUP ${entry.cupRate}`;
  if (entry.usdtSellGyd !== null) return `USDT ${entry.usdtBuyGyd ?? "?"}/${entry.usdtSellGyd}`;
  return "—";
}

export function shortId(id: string | null): string {
  return id ? id.slice(0, 8) : "—";
}
