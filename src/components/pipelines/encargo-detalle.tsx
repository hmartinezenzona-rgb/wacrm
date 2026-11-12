"use client";

// ============================================================
// «Lo que lleva» en limpio — edición Doña Miriam.
//
// Muestra el texto del encargo como lo escribiría Miriam:
//
//   Charola 1:
//   • Congrí
//   • Fricasé de pollo
//
//   Extra: Ración extra de arroz
//   Nota: sin cebolla
//
// Lee los dos formatos (ver src/lib/encargos/leer.ts). El texto guardado
// no se toca.
// ============================================================

import { leerBloques, type BloqueEncargo } from "@/lib/encargos/leer";

export function leerEncargo(notes: string | null | undefined): BloqueEncargo[] | null {
  const bloques = leerBloques(notes);
  return bloques.some((b) => b.tipo === "charola") ? bloques : null;
}

export function EncargoDetalle({ bloques }: { bloques: BloqueEncargo[] }) {
  const datos = bloques.filter((b): b is Extract<BloqueEncargo, { tipo: "dato" }> => b.tipo === "dato");
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
