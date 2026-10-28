import { describe, expect, it } from "vitest";
import { FINANZAS_TABS, parseFinanzasTab } from "./tabs";

describe("parseFinanzasTab", () => {
  it("lists the tabs in reading order", () => {
    expect(FINANZAS_TABS).toEqual(["semana", "cierres", "operaciones"]);
  });

  it.each(FINANZAS_TABS)("keeps the known tab %s", (tab) => {
    expect(parseFinanzasTab(tab)).toBe(tab);
  });

  it.each([undefined, "", "nope", "SEMANA", ["cierres", "operaciones"]])("falls back to semana for %j", (value) => {
    expect(parseFinanzasTab(value)).toBe("semana");
  });
});
