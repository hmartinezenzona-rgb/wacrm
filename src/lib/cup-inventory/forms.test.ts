// Validation of what the owner types in the card and lot dialogs, before anything is sent.
import { describe, expect, it } from "vitest";
import { validateCardForm, validateLotForm } from "./forms";

describe("validateLotForm", () => {
  it("reads Spanish-typed numbers", () => {
    expect(validateLotForm({ amount: "500.000", rate: "960", note: " compra A " })).toEqual({
      ok: true,
      value: { amountCup: 500000, rateCupPerUsdt: 960, note: "compra A" },
    });
  });

  it("an empty note is left out", () => {
    expect(validateLotForm({ amount: "1000", rate: "1060,5", note: "  " })).toEqual({
      ok: true,
      value: { amountCup: 1000, rateCupPerUsdt: 1060.5 },
    });
  });

  it.each([
    ["", "960", "invalidAmount"],
    ["abc", "960", "invalidAmount"],
    ["0", "960", "invalidAmount"],
    ["1000", "", "invalidRate"],
    ["1000", "0", "invalidRate"],
    ["1000", "-3", "invalidRate"],
    ["1000", "1000000000", "invalidRate"],
  ])("amount %j rate %j -> %s", (amount, rate, errorKey) => {
    expect(validateLotForm({ amount, rate, note: "" })).toEqual({ ok: false, errorKey });
  });

  it("a note over 500 characters is refused", () => {
    expect(validateLotForm({ amount: "1", rate: "1", note: "x".repeat(501) })).toEqual({ ok: false, errorKey: "noteTooLong" });
  });
});

describe("validateCardForm", () => {
  it("accepts a name with the default limit", () => {
    expect(validateCardForm({ name: " Tarjeta A ", last4: "", dailyLimit: "120.000" })).toEqual({
      ok: true,
      value: { name: "Tarjeta A", last4: "", dailyLimitCup: 120000 },
    });
  });

  it("keeps a valid last4", () => {
    const result = validateCardForm({ name: "A", last4: "1234", dailyLimit: "90000" });
    expect(result).toEqual({ ok: true, value: { name: "A", last4: "1234", dailyLimitCup: 90000 } });
  });

  it.each([
    ["", "", "120000", "nameRequired"],
    ["   ", "", "120000", "nameRequired"],
    ["x".repeat(61), "", "120000", "nameTooLong"],
    ["A", "123", "120000", "invalidLast4"],
    ["A", "12ab", "120000", "invalidLast4"],
    ["A", "", "0", "invalidLimit"],
    ["A", "", "", "invalidLimit"],
  ])("name %j last4 %j limit %j -> %s", (name, last4, dailyLimit, errorKey) => {
    expect(validateCardForm({ name, last4, dailyLimit })).toEqual({ ok: false, errorKey });
  });
});
