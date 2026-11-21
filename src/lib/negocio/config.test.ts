import { describe, expect, it } from "vitest";
import {
  DEFAULT_NEGOCIO,
  columna,
  datoDeNotas,
  leerNegocio,
  mezclarTextos,
  resumenDeNotas,
  textoBoton,
} from "./config";

describe("leerNegocio", () => {
  it("sin fila usa los valores por defecto", () => {
    expect(leerNegocio(null)).toEqual(DEFAULT_NEGOCIO);
    expect(leerNegocio("basura")).toEqual(DEFAULT_NEGOCIO);
  });

  it("filtra secciones del menú que no existen", () => {
    const c = leerNegocio({ menu: ["pipelines", "hackeo", "cocinar"] });
    expect(c.menu).toEqual(["pipelines", "cocinar"]);
  });

  it("menú vacío cae al de por defecto", () => {
    expect(leerNegocio({ menu: [] }).menu).toEqual(DEFAULT_NEGOCIO.menu);
  });

  it("las columnas se buscan sin acentos ni mayúsculas", () => {
    const c = leerNegocio({ columnas: { "Llamada Agendada": { boton: "Ya agendamos", alerta_dias: 2 } } });
    expect(columna(c, "llamada agendada").alerta_dias).toBe(2);
    expect(textoBoton(c, "LLAMADA AGENDADA")).toBe("Ya agendamos");
    expect(textoBoton(c, "Propuesta enviada")).toBe("Pasar a Propuesta enviada");
    expect(columna(c, null)).toEqual({});
  });

  it("seguimiento sin columna se apaga", () => {
    expect(leerNegocio({ avisos: { seguimiento: { dias: 3 } } }).avisos.seguimiento).toBeNull();
    const s = leerNegocio({ avisos: { seguimiento: { columna: "Propuesta enviada" } } }).avisos.seguimiento;
    expect(s).toEqual({ columna: "Propuesta enviada", dias: 3, singular: "tarjeta", plural: "tarjetas" });
  });
});

describe("notas", () => {
  const notas = "Contacto: Ana\nGiro: estética\nReto: no contesta a tiempo\nLlamada: sábado 10 (por confirmar)";

  it("lee una línea sin importar mayúsculas", () => {
    expect(datoDeNotas(notas, "giro")).toBe("estética");
    expect(datoDeNotas(notas, "Llamada")).toBe("sábado 10 (por confirmar)");
    expect(datoDeNotas(notas, "correo")).toBe("");
    expect(datoDeNotas(null, "giro")).toBe("");
  });

  it("resume varias líneas", () => {
    expect(resumenDeNotas(notas, ["Giro", "Reto"])).toBe("estética · no contesta a tiempo");
    expect(resumenDeNotas(notas, ["Giro", "Correo"])).toBe("estética");
    expect(resumenDeNotas(notas, [])).toBe("");
  });
});

describe("mezclarTextos", () => {
  it("reemplaza solo lo que trae el negocio", () => {
    const base = { Sidebar: { pipelines: "Ventas", inbox: "Mensajes" }, Otro: { a: "1" } };
    const r = mezclarTextos(base, { Sidebar: { pipelines: "Encargos" } });
    expect(r).toEqual({ Sidebar: { pipelines: "Encargos", inbox: "Mensajes" }, Otro: { a: "1" } });
    expect(base.Sidebar.pipelines).toBe("Ventas");
  });
});
