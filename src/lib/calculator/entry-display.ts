/**
 * How an automatic (chat operation) ledger line reads in the Calculator and its text export.
 *
 * A SALDO_MOVIL line stores the saldo itself (packages x 360) in the currency "SM" (migration 223), so it reads
 * "1,800 SM" with the service "Saldo Móvil" instead of "5 SALDO_MOVIL". A saldo line whose deposit is not a whole
 * number of packages keeps the raw deposit in GYD. Every other service keeps the "amount SERVICE" reading.
 */

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

/**
 * "1,800 SM" for a saldo line; "<amount> <SERVICE>" (unchanged) for the others. A manual line reads the way it was typed:
 * "4000 GYD" for a direct line (visa, ext, ...) and "2 SALDO MOVIL" for saldo packages (currency REC, not a saldo amount).
 */
export function chatEntryAmountText(entry: { amount: number; amountCurrency: string; service: string }): string {
  if (entry.service === DIRECTO) return `${entry.amount} ${entry.amountCurrency}`;
  if (entry.service === SALDO_MOVIL && entry.amountCurrency === "REC") return `${entry.amount} ${calculatorCategoryName(entry.service)}`;
  if (entry.service !== SALDO_MOVIL) return `${entry.amount} ${entry.service}`;
  return `${entry.amount.toLocaleString("en-US", { maximumFractionDigits: 2 })} ${entry.amountCurrency}`;
}
