/**
 * How an automatic (chat operation) ledger line reads in the Calculator and its text export.
 *
 * A SALDO_MOVIL line stores the saldo itself (packages x 360) in the currency "SM" (migration 223), so it reads
 * "1 800 SM" with the service "Saldo móvil" instead of "5 SALDO_MOVIL". A saldo line whose deposit is not a whole
 * number of packages keeps the raw deposit in GYD. Every other service keeps the "amount SERVICE" reading.
 */

import { num } from "@/lib/finanzas/number-format";
import { formatNumber } from "@/lib/format-number";
import { serviceNameEs } from "@/lib/service-name";

const SALDO_MOVIL = "SALDO_MOVIL";
/** Ledger service of the manual calculator's direct lines (visa, ext, trabajo, estudiante, trad, combo, pasaje; migration 228). */
const DIRECTO = "DIRECTO";

/** On-screen name of a ledger service: the canonical name (src/lib/service-name.ts); an unknown key prints as it is. */
export function ledgerServiceLabel(service: string): string {
  return serviceNameEs(service) ?? service;
}

/** The manual calculator's own words for a ledger service, as the text box and the .txt export write them (the
 *  on-screen names come from `ledgerServiceLabel`). */
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

/** The same reading with the Finanzas tables' separators (comma thousands, dot decimals). */
export function chatEntryAmountCommaText(entry: ChatEntryAmount): string {
  return amountLine(entry, (value, max) => num(value, max));
}

/**
 * The same line for the Calculator's .txt export, which the owner pastes elsewhere: figures keep the plain format they
 * had before the display format changed ("1,800 SM", "45000 CUP").
 */
export function chatEntryAmountExportText(entry: ChatEntryAmount): string {
  return amountLine(entry, (value, max) => (max === 2 ? value.toLocaleString("en-US", { maximumFractionDigits: 2 }) : String(value)));
}
