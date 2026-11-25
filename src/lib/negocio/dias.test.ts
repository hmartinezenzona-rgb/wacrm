import { describe, expect, it } from "vitest";
import { diaCorto, resumenDias } from "./dias";

describe("resumenDias", () => {
  it("todos, ninguno y seguidos", () => {
    expect(resumenDias(null)).toBe("Todos los días");
    expect(resumenDias([0, 1, 2, 3, 4, 5, 6])).toBe("Todos los días");
    expect(resumenDias([])).toBe("Ningún día");
    expect(resumenDias([1, 2, 3, 4, 5, 6])).toBe("Lunes a sábado");
    expect(resumenDias([5, 6, 0])).toBe("Viernes a domingo");
  });

  it("sueltos", () => {
    expect(resumenDias([2, 4])).toBe("Martes y jueves");
    expect(resumenDias([6])).toBe("Sábado");
    expect(resumenDias([1, 3, 5])).toBe("Lunes, miércoles y viernes");
  });
});

describe("diaCorto", () => {
  it("nombre y número", () => {
    expect(diaCorto("2026-11-24")).toBe("martes 24");
  });
});
