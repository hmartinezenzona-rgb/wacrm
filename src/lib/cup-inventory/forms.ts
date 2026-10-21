// Validation of what the owner types in the CUP inventory dialogs. Pure: returns the body to send or the i18n key of the error.
import { parseCupNumber } from "./format";

export type FormResult<T> = { ok: true; value: T } | { ok: false; errorKey: string };

export function validateLotForm(input: { amount: string; rate: string; note: string }): FormResult<{
  amountCup: number;
  rateCupPerUsdt: number;
  note?: string;
}> {
  const amountCup = parseCupNumber(input.amount);
  if (amountCup === null || amountCup >= 1e12) return { ok: false, errorKey: "invalidAmount" };
  const rateCupPerUsdt = parseCupNumber(input.rate);
  if (rateCupPerUsdt === null || rateCupPerUsdt >= 1e9) return { ok: false, errorKey: "invalidRate" };
  const note = input.note.trim();
  if (note.length > 500) return { ok: false, errorKey: "noteTooLong" };
  return { ok: true, value: note === "" ? { amountCup, rateCupPerUsdt } : { amountCup, rateCupPerUsdt, note } };
}

export function validateCardForm(input: { name: string; last4: string; dailyLimit: string }): FormResult<{
  name: string;
  last4: string;
  dailyLimitCup: number;
}> {
  const name = input.name.trim();
  if (name === "") return { ok: false, errorKey: "nameRequired" };
  if (name.length > 60) return { ok: false, errorKey: "nameTooLong" };
  const last4 = input.last4.trim();
  if (last4 !== "" && !/^\d{4}$/.test(last4)) return { ok: false, errorKey: "invalidLast4" };
  const dailyLimitCup = parseCupNumber(input.dailyLimit);
  if (dailyLimitCup === null || dailyLimitCup >= 1e12) return { ok: false, errorKey: "invalidLimit" };
  return { ok: true, value: { name, last4, dailyLimitCup } };
}

const BALANCE_NUMBER = { allowZero: true, commaThousands: true } as const;

/** What the owner typed in the "Ajustar saldo" dialog: the real balance (zero allowed) and an optional reason. */
export function validateBalanceForm(input: { balance: string; reason: string; currentBalanceCup: number }): FormResult<{
  balanceCup: number;
  reason?: string;
}> {
  const balanceCup = parseCupNumber(input.balance, BALANCE_NUMBER);
  if (balanceCup === null || balanceCup >= 1e12) return { ok: false, errorKey: "invalidBalance" };
  if (balanceCup === input.currentBalanceCup) return { ok: false, errorKey: "balanceUnchanged" };
  const reason = input.reason.trim();
  if (reason.length > 500) return { ok: false, errorKey: "reasonTooLong" };
  return { ok: true, value: reason === "" ? { balanceCup } : { balanceCup, reason } };
}

/** Signed change the typed balance would make to the current one; null while the text is not a number. */
export function balanceDifference(balance: string, currentBalanceCup: number): number | null {
  const value = parseCupNumber(balance, BALANCE_NUMBER);
  return value === null ? null : value - currentBalanceCup;
}
