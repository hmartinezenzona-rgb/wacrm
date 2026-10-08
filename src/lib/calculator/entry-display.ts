/**
 * How an automatic (chat operation) ledger line reads in the Calculator and its text export.
 *
 * A SALDO_MOVIL line stores the saldo itself (packages x 360) in the currency "SM" (migration 223), so it reads
 * "1 800 SM" with the service "Saldo Móvil" instead of "5 SALDO_MOVIL". A saldo line whose deposit is not a whole
 * number of packages keeps the raw deposit in GYD. Every other service keeps the "amount SERVICE" reading.
 */

import { formatNumber } from "@/lib/format-number";

const SALDO_MOVIL = "SALDO_MOVIL";
/** Ledger service of the manual calculator's direct lines (visa, ext, trabajo, estudiante, trad, combo, pasaje; migration 228). */
const DIRECTO = "DIRECTO";

/** Human label of a ledger service key; the keys without one print as they are. */
export function ledgerServiceLabel(service: string): string {
  if (service === SALDO_MOVIL) return "Saldo Móvil";
  if (service === DIRECTO) return "Trámites / Combos / Servicios";
  return service;
}

/** The manual calculator's category name for a ledger service, so automatic and manual lines add up together. */
export function calculatorCategoryName(service: string): string {
  if (service === SALDO_MOVIL) return "SALDO MOVIL";
  if (service === DIRECTO) return "TRÁMITES / COMBOS / SERVICIOS";
  return service;
}

type ChatEntryAmount = { amount: number; amountCurrency: string; service: string };

/** Every digit the amount has; only the separators of the display format change. */
const AS_IS = { maximumFractionDigits: 20 };

function amountLine(entry: ChatEntryAmount, figure: (value: number, maxFractionDigits: number) => string): string {
  if (entry.service === DIRECTO) return `${figure(entry.amount, 20)} ${entry.amountCurrency}`;
  if (entry.service === SALDO_MOVIL && entry.amountCurrency === "REC") return `${figure(entry.amount, 20)} ${calculatorCategoryName(entry.service)}`;
  if (entry.service !== SALDO_MOVIL) return `${figure(entry.amount, 20)} ${entry.service}`;
  return `${figure(entry.amount, 2)} ${entry.amountCurrency}`;
}

/**
 * "1 800 SM" for a saldo line; "<amount> <SERVICE>" for the others, the amount written with the app's money format
 * (spaced thousands, decimal comma). A manual line reads the way it was typed: "4 000 GYD" for a direct line (visa,
 * ext, ...) and "2 SALDO MOVIL" for saldo packages (currency REC, not a saldo amount).
 */
export function chatEntryAmountText(entry: ChatEntryAmount): string {
  return amountLine(entry, (value, max) => formatNumber(value, { ...AS_IS, maximumFractionDigits: max }));
}

/**
 * The same line for the Calculator's .txt export, which the owner pastes elsewhere: figures keep the plain format they
 * had before the display format changed ("1,800 SM", "45000 CUP").
 */
export function chatEntryAmountExportText(entry: ChatEntryAmount): string {
  return amountLine(entry, (value, max) => (max === 2 ? value.toLocaleString("en-US", { maximumFractionDigits: 2 }) : String(value)));
}
