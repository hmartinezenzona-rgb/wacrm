import { describe, expect, it } from "vitest";
import { calculatorCategoryName, chatEntryAmountText, ledgerServiceLabel } from "./entry-display";

describe("chat entry display", () => {
  it("reads a saldo line as its saldo amount in SM with a thousands separator", () => {
    expect(chatEntryAmountText({ amount: 1800, amountCurrency: "SM", service: "SALDO_MOVIL" })).toBe("1,800 SM");
  });

  it("shows a saldo line without an exact package count as its raw deposit in GYD, never SM", () => {
    expect(chatEntryAmountText({ amount: 5500, amountCurrency: "GYD", service: "SALDO_MOVIL" })).toBe("5,500 GYD");
  });

  it("keeps the other services reading amount + service", () => {
    expect(chatEntryAmountText({ amount: 5, amountCurrency: "REC", service: "RECARGA" })).toBe("5 RECARGA");
    expect(chatEntryAmountText({ amount: 100, amountCurrency: "USD", service: "ZELLE" })).toBe("100 ZELLE");
  });

  it("labels SALDO_MOVIL as the manual calculator does and leaves the rest alone", () => {
    expect(ledgerServiceLabel("SALDO_MOVIL")).toBe("Saldo Móvil");
    expect(ledgerServiceLabel("RECARGA")).toBe("RECARGA");
    expect(calculatorCategoryName("SALDO_MOVIL")).toBe("SALDO MOVIL");
    expect(calculatorCategoryName("CUP")).toBe("CUP");
  });
});
