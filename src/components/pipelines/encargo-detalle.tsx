"use client";

// ============================================================
// «Lo que lleva» en limpio — edición Doña Miriam.
//
// Las notas del encargo se guardan como texto, una línea por cosa (así las
// escribe encargo_web y así las suma «Qué cocinar»):
//
//   Charola 1: Congrí, Fricasé de pollo, Tostones, Frijoles negros
//   Extra: Ración extra de arroz
//   Nota: sin cebolla
//   Anticipo: $150
//   Pidió por la página web · folio DM-ABC123
//
// Aquí se muestran en el mismo orden, pero cada charola como lista:
//
//   Charola 1:
//   • Congrí
//   • Fricasé de pollo
//   …
//   Extra: Ración extra de arroz
//   Nota: sin cebolla
//
// El texto guardado no se toca.
// ============================================================

type Bloque =
  | { tipo: "charola"; titulo: string; platos: string[] }
  | { tipo: "linea"; etiqueta: string; texto: string }
  | { tipo: "dato"; texto: string };

export function leerEncargo(notes: string | null | undefined): Bloque[] | null {
  const bloques: Bloque[] = [];
  let hayCharola = false;
  for (const cruda of (notes || "").split("\n")) {
    const linea = cruda.trim();
    if (!linea) continue;
    let m: RegExpMatchArray | null;
    if ((m = linea.match(/^(charola[^:]*):\s*(.+)$/i))) {
      hayCharola = true;
      bloques.push({
        tipo: "charola",
        titulo: m[1].trim(),
        platos: m[2].split(",").map((x) => x.trim()).filter(Boolean),
      });
    } else if ((m = linea.match(/^(extra|nota)\s*:\s*(.+)$/i))) {
      bloques.push({ tipo: "linea", etiqueta: m[1][0].toUpperCase() + m[1].slice(1).toLowerCase(), texto: m[2].trim() });
    } else {
      bloques.push({ tipo: "dato", texto: linea });
    }
  }
  return hayCharola ? bloques : null;
}

export function EncargoDetalle({ bloques }: { bloques: Bloque[] }) {
  const datos = bloques.filter((b): b is Extract<Bloque, { tipo: "dato" }> => b.tipo === "dato");
  return (
    <div className="flex flex-col gap-3 rounded-lg border border-border bg-muted/60 p-3 text-base leading-snug">
      {bloques.map((b, i) => {
        if (b.tipo === "charola") {
          return (
            <div key={i}>
              <p className="font-bold">{b.titulo}:</p>
              <ul className="mt-1 list-disc space-y-0.5 pl-5 marker:text-muted-foreground">
                {b.platos.map((p, k) => (
                  <li key={k}>{p}</li>
                ))}
              </ul>
            </div>
          );
        }
        if (b.tipo === "linea") {
          return (
            <p key={i} className={b.etiqueta === "Nota" ? "rounded-md bg-amber-500/15 px-2 py-1.5" : ""}>
              <span className="font-bold">{b.etiqueta}:</span> {b.texto}
            </p>
          );
        }
        return null;
      })}
      {datos.length > 0 && (
        <p className="border-t border-border/60 pt-2 text-sm text-muted-foreground">
          {datos.map((d) => d.texto).join(" · ")}
        </p>
      )}
    </div>
  );
}
