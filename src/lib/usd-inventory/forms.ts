// Validation of what the owner types in the USD inventory dialogs. Pure: returns the body to send or the i18n key of the error.
import type { FormResult } from "@/lib/cup-inventory/forms";
import { discountToUsdtPaid, parsePercent, parseUsdNumber } from "./format";
import type { UsdService } from "./read-model";

export type { FormResult };

/**
 * A lot buys `amount` USD for some USDT. The owner types either the USDT he paid or the discount he got ("5", "5%", "1x1"):
 * a typed USDT figure wins; otherwise USDT paid = amount / (1 + discount), rounded to cents (500 USD at 5% = 476.19).
 */
export function validateUsdLotForm(input: { amount: string; usdtPaid: string; discount: string; note: string }): FormResult<{
  amountUsd: number;
  usdtPaid: number;
  note?: string;
}> {
  const amountUsd = parseUsdNumber(input.amount);
  if (amountUsd === null || amountUsd >= 1e12) return { ok: false, errorKey: "invalidAmount" };

  let usdtPaid: number;
  if (input.usdtPaid.trim() !== "") {
    const typed = parseUsdNumber(input.usdtPaid);
    if (typed === null || typed >= 1e12) return { ok: false, errorKey: "invalidUsdtPaid" };
    usdtPaid = typed;
  } else if (input.discount.trim() !== "") {
    const percent = parsePercent(input.discount);
    if (percent === null) return { ok: false, errorKey: "invalidDiscount" };
    usdtPaid = discountToUsdtPaid(amountUsd, percent);
    if (usdtPaid <= 0) return { ok: false, errorKey: "invalidUsdtPaid" };
  } else {
    return { ok: false, errorKey: "invalidUsdtPaid" };
  }

  const note = input.note.trim();
  if (note.length > 500) return { ok: false, errorKey: "noteTooLong" };
  return { ok: true, value: note === "" ? { amountUsd, usdtPaid } : { amountUsd, usdtPaid, note } };
}

export function validateUsdCardForm(input: { service: UsdService; name: string; last4: string; monthlyLimit: string }): FormResult<{
  service: UsdService;
  name: string;
  last4: string;
  monthlyLimitUsd: number;
}> {
  const name = input.name.trim();
  if (name === "") return { ok: false, errorKey: "nameRequired" };
  if (name.length > 60) return { ok: false, errorKey: "nameTooLong" };
  const last4 = input.last4.trim();
  if (last4 !== "" && !/^\d{4}$/.test(last4)) return { ok: false, errorKey: "invalidLast4" };
  const monthlyLimitUsd = parseUsdNumber(input.monthlyLimit);
  if (monthlyLimitUsd === null || monthlyLimitUsd >= 1e12) return { ok: false, errorKey: "invalidLimit" };
  return { ok: true, value: { service: input.service, name, last4, monthlyLimitUsd } };
}

const BALANCE_NUMBER = { allowZero: true, commaThousands: true } as const;

/** What the owner typed in the "Ajustar saldo" dialog: the real balance (zero allowed) and an optional reason. */
export function validateUsdBalanceForm(input: { balance: string; reason: string; currentBalanceUsd: number }): FormResult<{
  balanceUsd: number;
  reason?: string;
}> {
  const balanceUsd = parseUsdNumber(input.balance, BALANCE_NUMBER);
  if (balanceUsd === null || balanceUsd >= 1e12) return { ok: false, errorKey: "invalidBalance" };
  if (balanceUsd === input.currentBalanceUsd) return { ok: false, errorKey: "balanceUnchanged" };
  const reason = input.reason.trim();
  if (reason.length > 500) return { ok: false, errorKey: "reasonTooLong" };
  return { ok: true, value: reason === "" ? { balanceUsd } : { balanceUsd, reason } };
}

/** Signed change the typed balance would make to the current one; null while the text is not a number. */
export function balanceDifferenceUsd(balance: string, currentBalanceUsd: number): number | null {
  const value = parseUsdNumber(balance, BALANCE_NUMBER);
  return value === null ? null : value - currentBalanceUsd;
}
