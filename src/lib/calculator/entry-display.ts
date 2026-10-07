/**
 * How an automatic (chat operation) ledger line reads in the Calculator and its text export.
 *
 * A SALDO_MOVIL line stores the saldo itself (packages x 360) in the currency "SM" (migration 223), so it reads
 * "1,800 SM" with the service "Saldo Móvil" instead of "5 SALDO_MOVIL". A saldo line whose deposit is not a whole
 * number of packages keeps the raw deposit in GYD. Every other service keeps the "amount SERVICE" reading.
 */

const SALDO_MOVIL = "SALDO_MOVIL";

/** Human label of a ledger service key; the keys without one print as they are. */
export function ledgerServiceLabel(service: string): string {
  return service === SALDO_MOVIL ? "Saldo Móvil" : service;
}

/** The manual calculator's category name for a ledger service, so automatic and manual lines add up together. */
export function calculatorCategoryName(service: string): string {
  return service === SALDO_MOVIL ? "SALDO MOVIL" : service;
}

/** "1,800 SM" for a saldo line; "<amount> <SERVICE>" (unchanged) for the others. */
export function chatEntryAmountText(entry: { amount: number; amountCurrency: string; service: string }): string {
  if (entry.service !== SALDO_MOVIL) return `${entry.amount} ${entry.service}`;
  return `${entry.amount.toLocaleString("en-US", { maximumFractionDigits: 2 })} ${entry.amountCurrency}`;
}
