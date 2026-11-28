import { describe, expect, it } from "vitest";
import { buildMexicoBeneficiaryChanges, buildMexicoBeneficiaryDatos, formatClabe, isMexicoBeneficiaryType, MEXICO_WITHDRAWAL_BANKS } from "./mexico";

describe("formatClabe", () => {
  it("groups an 18-digit CLABE 4-4-4-6 for reading", () => {
    expect(formatClabe("012345678901234567")).toBe("0123 4567 8901 234567");
  });

  it("returns the digits unchanged when they are not 18 long", () => {
    expect(formatClabe("12345")).toBe("12345");
  });
});

describe("isMexicoBeneficiaryType", () => {
  it("recognises the two México recipient types only", () => {
    expect(isMexicoBeneficiaryType("mexico_cuenta")).toBe(true);
    expect(isMexicoBeneficiaryType("mexico_retiro")).toBe(true);
    expect(isMexicoBeneficiaryType("zelle")).toBe(false);
  });
});

describe("MEXICO_WITHDRAWAL_BANKS", () => {
  it("lists the two cardless withdrawal networks", () => {
    expect([...MEXICO_WITHDRAWAL_BANKS]).toEqual(["Coppel", "BBVA"]);
  });
});

describe("buildMexicoBeneficiaryDatos", () => {
  const draft = { name: " Ana Lopez ", clabe: "0123 4567 8901 234567", bankName: " BBVA ", phone: "" };

  it("builds a bank account from the holder, the 18-digit CLABE (spaces dropped) and the bank", () => {
    expect(buildMexicoBeneficiaryDatos("mexico_cuenta", draft)).toEqual({
      ok: true,
      datos: { beneficiary_type: "mexico_cuenta", name: "Ana Lopez", clabe: "012345678901234567", bank_name: "BBVA" },
    });
  });

  it.each([
    ["a 17-digit CLABE", { ...draft, clabe: "01234567890123456" }, "invalidClabe"],
    ["a CLABE with letters", { ...draft, clabe: "01234567890123456X" }, "invalidClabe"],
    ["no holder", { ...draft, name: "  " }, "cannotBeEmpty"],
    ["no bank", { ...draft, bankName: "" }, "cannotBeEmpty"],
  ] as const)("refuses a bank account with %s", (_label, input, error) => {
    expect(buildMexicoBeneficiaryDatos("mexico_cuenta", input)).toEqual({ ok: false, error });
  });

  it("builds a cardless withdrawal from the receiver, a Coppel or BBVA network and the phone", () => {
    expect(
      buildMexicoBeneficiaryDatos("mexico_retiro", { name: "Luis", clabe: "", bankName: "Coppel", phone: "5234-5678" }),
    ).toEqual({ ok: true, datos: { beneficiary_type: "mexico_retiro", name: "Luis", bank_name: "Coppel", phone: "52345678" } });
  });

  it.each([
    ["a network that is not Coppel or BBVA", { name: "Luis", clabe: "", bankName: "Santander", phone: "52345678" }, "cannotBeEmpty"],
    ["a phone that is too short", { name: "Luis", clabe: "", bankName: "BBVA", phone: "1234" }, "invalidPhone"],
    ["no receiver", { name: "", clabe: "", bankName: "BBVA", phone: "52345678" }, "cannotBeEmpty"],
  ] as const)("refuses a withdrawal with %s", (_label, input, error) => {
    expect(buildMexicoBeneficiaryDatos("mexico_retiro", input)).toEqual({ ok: false, error });
  });
});

describe("buildMexicoBeneficiaryDatos with an amount (290)", () => {
  const draft = { name: "Ana", clabe: "012345678901234567", bankName: "BBVA", phone: "" };

  it("sends the USD that goes to this recipient as a number, and nothing when it is empty", () => {
    expect(buildMexicoBeneficiaryDatos("mexico_cuenta", { ...draft, amount: " 50.5 " })).toEqual({
      ok: true,
      datos: { beneficiary_type: "mexico_cuenta", name: "Ana", clabe: "012345678901234567", bank_name: "BBVA", amount: 50.5 },
    });
    expect(buildMexicoBeneficiaryDatos("mexico_cuenta", { ...draft, amount: "" })).toEqual({
      ok: true,
      datos: { beneficiary_type: "mexico_cuenta", name: "Ana", clabe: "012345678901234567", bank_name: "BBVA" },
    });
  });

  it("sends it for a withdrawal too, and refuses zero, negative or non-numeric", () => {
    expect(buildMexicoBeneficiaryDatos("mexico_retiro", { name: "Luis", clabe: "", bankName: "Coppel", phone: "52345678", amount: "20" })).toEqual({
      ok: true,
      datos: { beneficiary_type: "mexico_retiro", name: "Luis", bank_name: "Coppel", phone: "52345678", amount: 20 },
    });
    for (const amount of ["0", "-5", "abc"]) {
      expect(buildMexicoBeneficiaryDatos("mexico_cuenta", { ...draft, amount })).toEqual({ ok: false, error: "invalidAmount" });
    }
  });
});

describe("buildMexicoBeneficiaryChanges with an amount (290)", () => {
  const account = { beneficiaryType: "mexico_cuenta" as const, name: "Ana", clabe: "012345678901234567", bankName: "BBVA", phone: null, amount: null };
  const same = { name: "Ana", clabe: "012345678901234567", bankName: "BBVA", phone: "" };

  it("sends the amount only when it changed", () => {
    expect(buildMexicoBeneficiaryChanges(account, { ...same, amount: "" })).toEqual({ ok: true, changes: {} });
    expect(buildMexicoBeneficiaryChanges(account, { ...same, amount: "50" })).toEqual({ ok: true, changes: { amount: 50 } });
    expect(buildMexicoBeneficiaryChanges({ ...account, amount: 50 }, { ...same, amount: "50" })).toEqual({ ok: true, changes: {} });
  });

  it("clears it with null when the field is emptied, and refuses a bad number", () => {
    expect(buildMexicoBeneficiaryChanges({ ...account, amount: 50 }, { ...same, amount: "" })).toEqual({ ok: true, changes: { amount: null } });
    expect(buildMexicoBeneficiaryChanges(account, { ...same, amount: "0" })).toEqual({ ok: false, error: "invalidAmount" });
  });
});

describe("buildMexicoBeneficiaryChanges", () => {
  const account = { beneficiaryType: "mexico_cuenta" as const, name: "Ana Lopez", clabe: "012345678901234567", bankName: "BBVA", phone: null };
  const withdrawal = { beneficiaryType: "mexico_retiro" as const, name: "Luis Perez", clabe: null, bankName: "Coppel", phone: "52345678" };
  const same = { name: "Ana Lopez", clabe: "0123 4567 8901 234567", bankName: "BBVA", phone: "" };

  it("sends nothing for an untouched bank account", () => {
    expect(buildMexicoBeneficiaryChanges(account, same)).toEqual({ ok: true, changes: {} });
  });

  it("sends only the changed bank-account keys, with the CLABE digits", () => {
    expect(
      buildMexicoBeneficiaryChanges(account, { ...same, name: " Ana Maria Lopez ", clabe: "000000000000000001" }),
    ).toEqual({ ok: true, changes: { name: "Ana Maria Lopez", clabe: "000000000000000001" } });
  });

  it("never changes a bank account's phone", () => {
    expect(buildMexicoBeneficiaryChanges(account, { ...same, phone: "52345678" })).toEqual({ ok: true, changes: {} });
  });

  it("refuses a CLABE that is not 18 digits and a blank holder or bank", () => {
    expect(buildMexicoBeneficiaryChanges(account, { ...same, clabe: "1234" })).toEqual({ ok: false, error: "invalidClabe" });
    expect(buildMexicoBeneficiaryChanges(account, { ...same, name: " " })).toEqual({ ok: false, error: "cannotBeEmpty" });
    expect(buildMexicoBeneficiaryChanges(account, { ...same, bankName: "" })).toEqual({ ok: false, error: "cannotBeEmpty" });
  });

  it("sends only the changed withdrawal keys: receiver, network and phone", () => {
    expect(
      buildMexicoBeneficiaryChanges(withdrawal, { name: "Luis Perez", clabe: "", bankName: "BBVA", phone: "5234-9999" }),
    ).toEqual({ ok: true, changes: { bank_name: "BBVA", phone: "52349999" } });
  });

  it("refuses a withdrawal network other than Coppel or BBVA, a short phone and a blank receiver", () => {
    expect(buildMexicoBeneficiaryChanges(withdrawal, { name: "Luis Perez", clabe: "", bankName: "Santander", phone: "52345678" })).toEqual({ ok: false, error: "cannotBeEmpty" });
    expect(buildMexicoBeneficiaryChanges(withdrawal, { name: "Luis Perez", clabe: "", bankName: "BBVA", phone: "12" })).toEqual({ ok: false, error: "invalidPhone" });
    expect(buildMexicoBeneficiaryChanges(withdrawal, { name: "", clabe: "", bankName: "BBVA", phone: "52345678" })).toEqual({ ok: false, error: "cannotBeEmpty" });
  });
});
