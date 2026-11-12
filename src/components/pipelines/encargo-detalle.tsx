"use client";

// ============================================================
// «Lo que lleva» en limpio — edición Doña Miriam.
//
// Las notas del encargo se guardan como texto, una línea por cosa
// (así las escribe la página web / encargo_web y así las suma
// «Qué cocinar»):
//
//   Charola 1: Congrí, Fricasé de pollo, Tostones, Frijoles negros
//   Extra: Ración extra de arroz
//   Nota: sin cebolla
//   Anticipo: $150
//   Pidió por la página web · folio DM-ABC123
//
// Aquí se muestran como tarjetitas fáciles de leer: cada charola con su
// arroz, carne, vianda y potaje; las iguales se juntan («× 2»); la nota
// del cliente resaltada. El texto original no se toca.
// ============================================================

const PARTES = [
  { emoji: "🍚", titulo: "Arroz" },
  { emoji: "🍖", titulo: "Carne" },
  { emoji: "🍌", titulo: "Vianda" },
  { emoji: "🫘", titulo: "Potaje" },
];

interface Charola {
  partes: string[];
  extras: string[];
}

export interface EncargoLeido {
  charolas: { charola: Charola; veces: number }[];
  extrasSueltos: string[];
  nota: string | null;
  anticipo: string | null;
  otros: string[];
}

export function leerEncargo(notes: string | null | undefined): EncargoLeido | null {
  const lista: Charola[] = [];
  const extrasSueltos: string[] = [];
  const otros: string[] = [];
  let nota: string | null = null;
  let anticipo: string | null = null;

  for (const cruda of (notes || "").split("\n")) {
    const linea = cruda.trim();
    if (!linea) continue;
    let m: RegExpMatchArray | null;
    if ((m = linea.match(/^charola[^:]*:\s*(.+)$/i))) {
      lista.push({ partes: m[1].split(",").map((x) => x.trim()).filter(Boolean), extras: [] });
    } else if ((m = linea.match(/^extra\s*:\s*(.+)$/i))) {
      if (lista.length) lista[lista.length - 1].extras.push(m[1].trim());
      else extrasSueltos.push(m[1].trim());
    } else if ((m = linea.match(/^nota\s*:\s*(.+)$/i))) {
      nota = nota ? `${nota} · ${m[1].trim()}` : m[1].trim();
    } else if ((m = linea.match(/^anticipo\s*:\s*(.+)$/i))) {
      anticipo = m[1].trim();
    } else {
      otros.push(linea);
    }
  }
  if (!lista.length) return null;

  // Juntar charolas idénticas (mismo plato y mismos extras).
  const juntas: { charola: Charola; veces: number }[] = [];
  for (const c of lista) {
    const clave = JSON.stringify(c);
    const ya = juntas.find((j) => JSON.stringify(j.charola) === clave);
    if (ya) ya.veces++;
    else juntas.push({ charola: c, veces: 1 });
  }
  return { charolas: juntas, extrasSueltos, nota, anticipo, otros };
}

export function EncargoDetalle({ encargo }: { encargo: EncargoLeido }) {
  // Número de la primera charola de cada grupo (1, 3, 4…).
  const inicios = encargo.charolas.reduce<number[]>(
    (acc, g, i) => [...acc, i === 0 ? 1 : acc[i - 1] + encargo.charolas[i - 1].veces],
    [],
  );
  return (
    <div className="flex flex-col gap-2.5">
      {encargo.charolas.map(({ charola, veces }, i) => {
        const desde = inicios[i];
        const hasta = desde + veces - 1;
        const titulo = veces > 1 ? `Charolas ${desde} a ${hasta}` : `Charola ${desde}`;
        return (
          <div key={i} className="overflow-hidden rounded-xl border border-border bg-muted/60">
            <div className="flex items-center justify-between gap-2 border-b border-border/60 px-3 py-2">
              <span className="text-sm font-bold">{titulo}</span>
              {veces > 1 && (
                <span className="rounded-full bg-primary px-2.5 py-0.5 text-sm font-bold text-primary-foreground">× {veces}</span>
              )}
            </div>
            <dl className="divide-y divide-border/50">
              {charola.partes.map((p, k) => (
                <div key={k} className="flex items-baseline gap-3 px-3 py-2">
                  <dt className="w-20 shrink-0 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                    {PARTES[k] ? `${PARTES[k].emoji} ${PARTES[k].titulo}` : "•"}
                  </dt>
                  <dd className="min-w-0 text-base font-semibold">{p}</dd>
                </div>
              ))}
              {charola.extras.map((e, k) => (
                <div key={`e${k}`} className="flex items-baseline gap-3 px-3 py-2">
                  <dt className="w-20 shrink-0 text-xs font-semibold uppercase tracking-wider text-muted-foreground">➕ Extra</dt>
                  <dd className="min-w-0 text-base font-semibold">{e}</dd>
                </div>
              ))}
            </dl>
          </div>
        );
      })}

      {encargo.extrasSueltos.length > 0 && (
        <div className="rounded-xl border border-border bg-muted/60 px-3 py-2">
          <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">➕ Extras</span>
          <ul className="mt-1 text-base font-semibold">
            {encargo.extrasSueltos.map((e, k) => (
              <li key={k}>{e}</li>
            ))}
          </ul>
        </div>
      )}

      {encargo.nota && (
        <div className="rounded-xl border border-amber-500/40 bg-amber-500/10 px-3 py-2.5">
          <span className="text-xs font-semibold uppercase tracking-wider text-amber-600 dark:text-amber-300">📝 Nota del cliente</span>
          <p className="mt-0.5 text-base font-semibold">{encargo.nota}</p>
        </div>
      )}

      {(encargo.anticipo || encargo.otros.length > 0) && (
        <p className="text-sm text-muted-foreground">
          {[encargo.anticipo ? `Anticipo ${encargo.anticipo}` : null, ...encargo.otros].filter(Boolean).join(" · ")}
        </p>
      )}
    </div>
  );
}
