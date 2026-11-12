// ============================================================
// Lee el texto «Lo que lleva» de un encargo — edición Doña Miriam.
//
// Lo usan la ficha del encargo, «Qué cocinar» y el resumen de la noche.
// Entiende los dos formatos:
//
//   Charola 1: Congrí, Fricasé de pollo, Tostones        (una línea)
//
//   Charola 1:                                          (lista)
//   - Congrí
//   - Fricasé de pollo
//
// y además «Extra: …», «Nota: …». Cualquier otra línea es un dato suelto
// (anticipo, folio, etc.).
// ============================================================

export type BloqueEncargo =
  | { tipo: "charola"; titulo: string; platos: string[] }
  | { tipo: "linea"; etiqueta: "Extra" | "Nota"; texto: string }
  | { tipo: "dato"; texto: string };

export function leerBloques(notes: string | null | undefined): BloqueEncargo[] {
  const bloques: BloqueEncargo[] = [];
  let actual: Extract<BloqueEncargo, { tipo: "charola" }> | null = null;
  for (const cruda of (notes || "").split("\n")) {
    const linea = cruda.trim();
    if (!linea) {
      actual = null;
      continue;
    }
    let m: RegExpMatchArray | null;
    if ((m = linea.match(/^(charola[^:]*):\s*(.*)$/i))) {
      actual = {
        tipo: "charola",
        titulo: m[1].trim(),
        platos: m[2].split(",").map((x) => x.trim()).filter(Boolean),
      };
      bloques.push(actual);
    } else if (actual && (m = linea.match(/^[-•*·]\s*(.+)$/))) {
      actual.platos.push(m[1].trim());
    } else if ((m = linea.match(/^(extra|nota)s?\s*:\s*(.+)$/i))) {
      actual = null;
      bloques.push({ tipo: "linea", etiqueta: /^e/i.test(m[1]) ? "Extra" : "Nota", texto: m[2].trim() });
    } else {
      actual = null;
      bloques.push({ tipo: "dato", texto: linea });
    }
  }
  return bloques;
}

/** Totales para la cocina: charolas, cuántas veces cada plato, extras y notas. */
export function sumarEncargo(notes: string | null | undefined) {
  let charolas = 0;
  const platos: Record<string, number> = {};
  const extras: Record<string, number> = {};
  const notas: string[] = [];
  for (const b of leerBloques(notes)) {
    if (b.tipo === "charola") {
      charolas++;
      for (const p of b.platos) platos[p] = (platos[p] || 0) + 1;
    } else if (b.tipo === "linea" && b.etiqueta === "Extra") {
      extras[b.texto] = (extras[b.texto] || 0) + 1;
    } else if (b.tipo === "linea") {
      notas.push(b.texto);
    }
  }
  return { charolas, platos, extras, notas };
}
