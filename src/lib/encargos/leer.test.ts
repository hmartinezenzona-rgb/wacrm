import { describe, expect, it } from "vitest";
import { leerBloques, sumarEncargo } from "./leer";

describe("leerBloques con la palabra del negocio", () => {
  it("lee «Orden 1:» cuando el negocio vende órdenes", () => {
    const b = leerBloques("Orden 1: Pastor, Salsa verde\nExtra: Horchata", "orden");
    expect(b[0]).toEqual({ tipo: "charola", titulo: "Orden 1", platos: ["Pastor", "Salsa verde"] });
    expect(b[1]).toEqual({ tipo: "linea", etiqueta: "Extra", texto: "Horchata" });
  });

  it("sigue entendiendo «Charola» aunque el negocio use otra palabra", () => {
    expect(sumarEncargo("Charola 1: Congrí\nCharola 2: Congrí", "orden").charolas).toBe(2);
  });

  it("sin palabra se comporta como antes", () => {
    const s = sumarEncargo("Charola 1: Congrí, Ropa vieja\nNota: sin cebolla");
    expect(s.platos).toEqual({ Congrí: 1, "Ropa vieja": 1 });
    expect(s.notas).toEqual(["sin cebolla"]);
  });
});
