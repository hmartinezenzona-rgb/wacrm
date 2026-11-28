import { describe, expect, it } from "vitest";
import { SERVICE_COLORS, serviceColor, serviceDotClass } from "./service-color";

describe("serviceColor", () => {
  it.each([
    ["CUP", "cup"],
    ["ZELLE", "zelle"],
    ["MLC", "mlc"],
    ["TROPICAL", "tropical"],
    ["CLASICA", "clasica"],
    ["USDT", "usdt"],
    ["EFECTIVO", "efectivo"],
    ["RECARGA", "recarga"],
    ["SALDO_MOVIL", "saldo"],
    ["DIRECTO", "directo"],
    ["remesa", "remesa"],
    ["visa", "visa"],
    ["recarga", "recarga"],
    ["saldo", "saldo"],
    ["combo", "directo"],
    ["traduccion", "directo"],
    ["mexico", "directo"],
    ["cuban_card", "cup"],
    ["efectivo_usd", "efectivo"],
    ["zelle", "zelle"],
    ["clasica", "clasica"],
    ["tropical", "tropical"],
  ])("maps %s to %s", (service, color) => {
    expect(serviceColor(service)).toBe(color);
  });

  it("gives the same colour to the ledger key and the operation type of one service", () => {
    expect(serviceColor("RECARGA")).toBe(serviceColor("recarga"));
    expect(serviceColor("SALDO_MOVIL")).toBe(serviceColor("saldo"));
    expect(serviceColor("ZELLE")).toBe(serviceColor("zelle"));
  });

  it("falls back to other for an unknown, empty or missing service", () => {
    expect(serviceColor("something_new")).toBe("other");
    expect(serviceColor("")).toBe("other");
    expect(serviceColor(null)).toBe("other");
    expect(serviceColor(undefined)).toBe("other");
  });

  it("has a literal class for every colour and they are all different", () => {
    const classes = SERVICE_COLORS.map((c) => serviceDotClass[c]);
    expect(classes).toContain("bg-service-cup");
    expect(classes).toContain("bg-service-other");
    expect(new Set(classes).size).toBe(SERVICE_COLORS.length);
  });
});
