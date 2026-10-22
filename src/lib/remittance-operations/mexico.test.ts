import { describe, expect, it } from "vitest";
import { buildMexicoBeneficiaryDatos, formatClabe, isMexicoBeneficiaryType, MEXICO_WITHDRAWAL_BANKS } from "./mexico";

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
