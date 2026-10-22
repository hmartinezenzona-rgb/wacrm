import { describe, expect, it } from "vitest";
import { formatClabe, isMexicoBeneficiaryType, MEXICO_WITHDRAWAL_BANKS } from "./mexico";

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
