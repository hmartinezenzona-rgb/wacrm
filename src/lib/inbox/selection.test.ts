import { describe, expect, it } from "vitest";
import {
  alternarSeleccion,
  etiquetaSeleccion,
  laAbiertaSeVa,
  parcheOcultar,
  parcheRestaurar,
  reconciliarSeleccion,
  textoConfirmacion,
  textoQuitadas,
} from "./selection";

describe("quitar del inbox conserva la semántica que ya existía", () => {
  it("escribe deleted_at y nada más", () => {
    const p = parcheOcultar(new Date("2026-09-06T21:00:00.000Z"));
    expect(p).toEqual({ deleted_at: "2026-09-06T21:00:00.000Z" });
  });

  it("no toca status: `closed` en esta aplicación es otra cosa", () => {
    expect(Object.keys(parcheOcultar())).toEqual(["deleted_at"]);
    expect(Object.keys(parcheRestaurar())).toEqual(["deleted_at"]);
  });

  it("deshacer devuelve deleted_at a null, no borra nada", () => {
    expect(parcheRestaurar()).toEqual({ deleted_at: null });
  });
});

describe("selección", () => {
  it("marca una", () => {
    expect([...alternarSeleccion(new Set(), "a")]).toEqual(["a"]);
  });

  it("marca varias", () => {
    let s = new Set<string>();
    s = alternarSeleccion(s, "a");
    s = alternarSeleccion(s, "b");
    expect(s.size).toBe(2);
  });

  it("desmarca la que ya estaba", () => {
    const s = alternarSeleccion(new Set(["a", "b"]), "a");
    expect([...s]).toEqual(["b"]);
  });

  it("no muta el conjunto original", () => {
    const original = new Set(["a"]);
    alternarSeleccion(original, "b");
    expect([...original]).toEqual(["a"]);
  });
});

describe("reconciliación cuando una fila desaparece", () => {
  it("quita de la selección lo que ya no está en la lista", () => {
    const s = reconciliarSeleccion(new Set(["a", "b", "c"]), ["a", "c"]);
    expect([...s].sort()).toEqual(["a", "c"]);
  });

  it("no deja contador fantasma si desaparecen todas", () => {
    expect(reconciliarSeleccion(new Set(["a"]), []).size).toBe(0);
  });

  it("deja la selección igual si no desaparece ninguna", () => {
    expect(reconciliarSeleccion(new Set(["a", "b"]), ["a", "b", "c"]).size).toBe(2);
  });
});

describe("textos", () => {
  it("singular y plural del contador", () => {
    expect(etiquetaSeleccion(1)).toBe("1 seleccionada");
    expect(etiquetaSeleccion(4)).toBe("4 seleccionadas");
  });

  it("la confirmación dice que el historial se conserva", () => {
    expect(textoConfirmacion(1)).toContain("¿Quitar esta conversación del inbox?");
    expect(textoConfirmacion(4)).toContain("¿Quitar 4 conversaciones del inbox?");
    expect(textoConfirmacion(4)).toContain("El historial se conserva.");
  });

  it("la confirmación no mete nombres ni teléfonos", () => {
    expect(textoConfirmacion(3)).not.toMatch(/\d{6,}/);
  });

  it("el aviso posterior usa «quitada del inbox», no «cerrada»", () => {
    expect(textoQuitadas(1)).toBe("1 conversación quitada del inbox");
    expect(textoQuitadas(4)).toBe("4 conversaciones quitadas del inbox");
    expect(textoQuitadas(1)).not.toMatch(/cerrad/i);
  });
});

describe("la conversación abierta", () => {
  it("se suelta si es una de las quitadas", () => {
    expect(laAbiertaSeVa("b", ["a", "b"])).toBe(true);
  });

  it("se queda si no lo es", () => {
    expect(laAbiertaSeVa("z", ["a", "b"])).toBe(false);
  });

  it("sin conversación abierta no hay nada que soltar", () => {
    expect(laAbiertaSeVa(null, ["a"])).toBe(false);
  });
});
