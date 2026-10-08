import { describe, expect, it } from "vitest";
import { calculatorCategoryName, chatEntryAmountExportText, chatEntryAmountText, ledgerServiceLabel } from "./entry-display";

const N = "\u202f";

describe("chat entry display", () => {
  it("reads a saldo line as its saldo amount in SM with spaced thousands", () => {
    expect(chatEntryAmountText({ amount: 1800, amountCurrency: "SM", service: "SALDO_MOVIL" })).toBe(`1${N}800 SM`);
  });

  it("shows a saldo line without an exact package count as its raw deposit in GYD, never SM", () => {
    expect(chatEntryAmountText({ amount: 5500, amountCurrency: "GYD", service: "SALDO_MOVIL" })).toBe(`5${N}500 GYD`);
  });

  it("keeps the other services reading amount + service", () => {
    expect(chatEntryAmountText({ amount: 5, amountCurrency: "REC", service: "RECARGA" })).toBe("5 RECARGA");
    expect(chatEntryAmountText({ amount: 100, amountCurrency: "USD", service: "ZELLE" })).toBe("100 ZELLE");
  });

  it("reads a manual line the way the manual calculator wrote it: 100 ZELLE, 45000 CUP, 4000 GYD, 2 SALDO MOVIL", () => {
    expect(chatEntryAmountText({ amount: 45000, amountCurrency: "CUP", service: "CUP" })).toBe(`45${N}000 CUP`);
    expect(chatEntryAmountText({ amount: 4000, amountCurrency: "GYD", service: "DIRECTO" })).toBe(`4${N}000 GYD`);
    // packages typed by hand (currency REC), not a saldo amount in SM
    expect(chatEntryAmountText({ amount: 2, amountCurrency: "REC", service: "SALDO_MOVIL" })).toBe("2 SALDO MOVIL");
  });

  it("names a ledger service with the canonical name and prints an unknown key as it is", () => {
    expect(ledgerServiceLabel("SALDO_MOVIL")).toBe("Saldo móvil");
    expect(ledgerServiceLabel("RECARGA")).toBe("Recarga");
    expect(ledgerServiceLabel("ZELLE")).toBe("Zelle");
    expect(ledgerServiceLabel("CLASICA")).toBe("Clásica");
    expect(ledgerServiceLabel("EFECTIVO")).toBe("Efectivo USD");
    expect(ledgerServiceLabel("CUP")).toBe("CUP");
    expect(ledgerServiceLabel("XYZ")).toBe("XYZ");
    // the manual calculator's group for its direct lines (visa, ext, trabajo, trad, combo, pasaje)
    expect(ledgerServiceLabel("DIRECTO")).toBe("Trámites");
    expect(calculatorCategoryName("SALDO_MOVIL")).toBe("SALDO MOVIL");
    expect(calculatorCategoryName("CUP")).toBe("CUP");
    // the text grammar and the .txt export keep the manual calculator's own words
    expect(calculatorCategoryName("DIRECTO")).toBe("TRÁMITES / COMBOS / SERVICIOS");
  });
});

describe("chat entry export text", () => {
  // The .txt export is pasted elsewhere, so its figures keep the format they had before the display change.
  it("keeps the export lines exactly as before", () => {
    expect(chatEntryAmountExportText({ amount: 1800, amountCurrency: "SM", service: "SALDO_MOVIL" })).toBe("1,800 SM");
    expect(chatEntryAmountExportText({ amount: 45000, amountCurrency: "CUP", service: "CUP" })).toBe("45000 CUP");
    expect(chatEntryAmountExportText({ amount: 4000, amountCurrency: "GYD", service: "DIRECTO" })).toBe("4000 GYD");
  });
});
