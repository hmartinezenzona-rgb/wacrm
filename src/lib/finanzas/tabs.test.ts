import { describe, expect, it } from "vitest";
import { FINANZAS_TABS, parseFinanzasTab } from "./tabs";

describe("parseFinanzasTab", () => {
  it("has no Operaciones tab any more", () => {
    expect((FINANZAS_TABS as readonly string[]).includes("operaciones")).toBe(false);
  });

  it("lists the tabs in reading order", () => {
    expect(FINANZAS_TABS).toEqual(["semana", "cierres", "revendedores"]);
  });

  it.each(FINANZAS_TABS)("keeps the known tab %s", (tab) => {
    expect(parseFinanzasTab(tab)).toBe(tab);
  });

  it.each([undefined, "", "nope", "SEMANA", ["cierres", "semana"]])("falls back to semana for %j", (value) => {
    expect(parseFinanzasTab(value)).toBe("semana");
  });
});
