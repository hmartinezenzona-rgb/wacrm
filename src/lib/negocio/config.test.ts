import { describe, expect, it } from "vitest";
import {
  DEFAULT_NEGOCIO,
  claveGrupo,
  cuantas,
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

describe("pedido, tema y vista sencilla", () => {
  it("sin datos usa los grupos de Doña Miriam y la palabra charola", () => {
    const c = leerNegocio({});
    expect(c.pedido.uno).toBe("charola");
    expect(c.pedido.grupos.map((g) => g.id)).toEqual(["arroz", "carne", "vianda", "potaje", "extra"]);
    expect(c.tema).toBeNull();
    expect(c.sencillo).toBe(false);
  });

  it("lee palabras y grupos libres, con clave sin acentos y sin repetidos", () => {
    const c = leerNegocio({
      tema: "cubano",
      sencillo: true,
      pedido: {
        uno: "orden",
        varios: "órdenes",
        grupos: [
          { nombre: "Guarnición" },
          { id: "salsa", nombre: "Salsas", tipo: "opcional" },
          { id: "salsa", nombre: "Otra", tipo: "uno" },
          { nombre: "Bebidas", tipo: "extra" },
          { nombre: "" },
        ],
      },
    });
    expect(c.tema).toBe("cubano");
    expect(c.sencillo).toBe(true);
    expect(c.pedido.varios).toBe("órdenes");
    expect(c.pedido.grupos).toEqual([
      { id: "guarnicion", nombre: "Guarnición", tipo: "uno" },
      { id: "salsa", nombre: "Salsas", tipo: "opcional" },
      { id: "bebidas", nombre: "Bebidas", tipo: "extra" },
    ]);
  });

  it("ignora un tema que no existe", () => {
    expect(leerNegocio({ tema: "neon" }).tema).toBeNull();
  });

  it("claveGrupo y cuantas", () => {
    expect(claveGrupo("Plato fuerte (día)")).toBe("plato_fuerte_dia");
    const c = leerNegocio({ pedido: { uno: "orden", varios: "órdenes" } });
    expect(cuantas(c, 1)).toBe("1 orden");
    expect(cuantas(c, 3)).toBe("3 órdenes");
  });
});
