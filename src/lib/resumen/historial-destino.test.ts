import { describe, expect, it } from "vitest";
import { historialDestino } from "./historial-destino";

describe("historialDestino", () => {
  it("card remittance: name and masked card", () => {
    expect(historialDestino({ beneficiario: "Pedro Pérez", tarjeta: "9205****9412" })).toBe("Pedro Pérez · 9205****9412");
  });

  it("beneficiary without a card (Zelle, Clásica…): the name alone", () => {
    expect(historialDestino({ beneficiario: "María", tarjeta: null })).toBe("María");
  });

  it("a card with no name still shows the card", () => {
    expect(historialDestino({ beneficiario: "  ", tarjeta: "9205****9412" })).toBe("9205****9412");
  });

  it("no beneficiary at all (recargas and other services): a dash", () => {
    expect(historialDestino({ beneficiario: null, tarjeta: null })).toBe("—");
    expect(historialDestino({ beneficiario: "", tarjeta: "" })).toBe("—");
  });
});
