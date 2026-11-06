import { describe, expect, it } from "vitest";
import { balanceDifferenceUsd, validateUsdBalanceForm, validateUsdCardForm, validateUsdLotForm } from "./forms";

const lot = (over: Partial<Parameters<typeof validateUsdLotForm>[0]> = {}) =>
  validateUsdLotForm({ amount: "500", usdtPaid: "", discount: "5", note: "", ...over });

describe("validateUsdLotForm", () => {
  it("500 USD at 5% fills usdtPaid = 476.19", () => {
    expect(lot()).toEqual({ ok: true, value: { amountUsd: 500, usdtPaid: 476.19 } });
  });
  it("1x1 -> 500", () => {
    expect(lot({ discount: "1x1" })).toEqual({ ok: true, value: { amountUsd: 500, usdtPaid: 500 } });
  });
  it("typed USDT paid wins over the discount", () => {
    expect(lot({ usdtPaid: "470", discount: "5" })).toEqual({ ok: true, value: { amountUsd: 500, usdtPaid: 470 } });
  });
  it("needs usdtPaid or a discount", () => {
    expect(lot({ discount: "" })).toEqual({ ok: false, errorKey: "invalidUsdtPaid" });
  });
  it("bad amount / discount / note", () => {
    expect(lot({ amount: "0" })).toEqual({ ok: false, errorKey: "invalidAmount" });
    expect(lot({ discount: "abc" })).toEqual({ ok: false, errorKey: "invalidDiscount" });
    expect(lot({ note: "x".repeat(501) })).toEqual({ ok: false, errorKey: "noteTooLong" });
  });
  it("keeps a trimmed note", () => {
    expect(lot({ note: " hola " })).toEqual({ ok: true, value: { amountUsd: 500, usdtPaid: 476.19, note: "hola" } });
  });
});

describe("validateUsdCardForm", () => {
  it("accepts a card", () => {
    expect(validateUsdCardForm({ service: "CLASICA", name: " A ", last4: "1234", monthlyLimit: "5.000" })).toEqual({
      ok: true, value: { service: "CLASICA", name: "A", last4: "1234", monthlyLimitUsd: 5000 },
    });
  });
  it("rejects bad input", () => {
    expect(validateUsdCardForm({ service: "CLASICA", name: "", last4: "", monthlyLimit: "5000" })).toEqual({ ok: false, errorKey: "nameRequired" });
    expect(validateUsdCardForm({ service: "CLASICA", name: "A", last4: "12", monthlyLimit: "5000" })).toEqual({ ok: false, errorKey: "invalidLast4" });
    expect(validateUsdCardForm({ service: "CLASICA", name: "A", last4: "", monthlyLimit: "0" })).toEqual({ ok: false, errorKey: "invalidLimit" });
    expect(validateUsdCardForm({ service: "CLASICA", name: "x".repeat(61), last4: "", monthlyLimit: "5" })).toEqual({ ok: false, errorKey: "nameTooLong" });
  });
});

describe("validateUsdBalanceForm / balanceDifferenceUsd", () => {
  it("accepts zero and a changed value", () => {
    expect(validateUsdBalanceForm({ balance: "0", reason: "", currentBalanceUsd: 10 })).toEqual({ ok: true, value: { balanceUsd: 0 } });
    expect(validateUsdBalanceForm({ balance: "395", reason: " r ", currentBalanceUsd: 400 })).toEqual({ ok: true, value: { balanceUsd: 395, reason: "r" } });
  });
  it("rejects unchanged and invalid", () => {
    expect(validateUsdBalanceForm({ balance: "400", reason: "", currentBalanceUsd: 400 })).toEqual({ ok: false, errorKey: "balanceUnchanged" });
    expect(validateUsdBalanceForm({ balance: "x", reason: "", currentBalanceUsd: 400 })).toEqual({ ok: false, errorKey: "invalidBalance" });
  });
  it("difference", () => {
    expect(balanceDifferenceUsd("395", 400)).toBe(-5);
    expect(balanceDifferenceUsd("x", 400)).toBeNull();
  });
});
