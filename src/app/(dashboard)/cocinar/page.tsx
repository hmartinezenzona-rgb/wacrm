"use client";

// ============================================================
// Qué cocinar — edición Doña Miriam.
//
// Suma lo que hay que preparar un día a partir de los encargos del
// tablero. Cada encargo es un deal; n8n lo crea desde la página web con
// la entrega en `expected_close_date` y el detalle en `notes`, una línea
// por cosa:
//
//   Charola 1: Congrí, Fricasé de pollo, Tostones, Frijoles negros
//   Extra: Ración extra de arroz
//   Nota: sin cebolla
//
// Las etapas cuyo nombre contiene "cancel" no cuentan. No toca nada:
// solo lee.
// ============================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { ChefHat, Loader2 } from "lucide-react";
import { sumarEncargo } from "@/lib/encargos/leer";

interface Fila {
  id: string;
  title: string;
  notes: string | null;
  expected_close_date: string | null;
  stage: { name: string } | null;
}

const GRUPOS: [string, string[]][] = [
  ["Arroz", ["Congrí", "Arroz blanco", "Arroz amarillo"]],
  ["Carne", ["Fricasé de puerco", "Fricasé de pollo", "Bistec de puerco", "Ropa vieja", "Picadillo de res", "Chuleta de puerco"]],
  ["Vianda", ["Papa con mojo", "Boniato", "Platanito maduro frito", "Tostones"]],
  ["Potaje", ["Frijoles negros", "Frijoles colorados", "Chícharo"]],
];
const DIAS = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"];
const MESES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];

function isoLocal(d: Date) {
  const z = new Date(d.getTime() - d.getTimezoneOffset() * 60000);
  return z.toISOString().slice(0, 10);
}
function etiqueta(iso: string, hoy: string, manana: string) {
  if (iso === hoy) return "Hoy";
  if (iso === manana) return "Mañana";
  const d = new Date(iso + "T12:00:00");
  return `${DIAS[d.getDay()].slice(0, 3)} ${d.getDate()}`;
}
function largo(iso: string) {
  const d = new Date(iso + "T12:00:00");
  return `${DIAS[d.getDay()]} ${d.getDate()} de ${MESES[d.getMonth()]}`;
}

export default function CocinarPage() {
  const supabase = useMemo(() => createClient(), []);
  // Hoy y mañana se fijan al abrir la pantalla.
  const [{ hoy, manana }] = useState(() => {
    const ahora = new Date();
    return { hoy: isoLocal(ahora), manana: isoLocal(new Date(ahora.getTime() + 86400000)) };
  });
  const [filas, setFilas] = useState<Fila[]>([]);
  const [cargando, setCargando] = useState(true);
  const [dia, setDia] = useState(hoy);

  const cargar = useCallback(async () => {
    const { data } = await supabase
      .from("deals")
      .select("id,title,notes,expected_close_date,stage:pipeline_stages(name)")
      .gte("expected_close_date", hoy)
      .order("expected_close_date");
    setFilas(((data as unknown as Fila[]) || []).filter((f) => !/cancel/i.test(f.stage?.name || "")));
    setCargando(false);
  }, [supabase, hoy]);

  useEffect(() => {
    // Carga inicial desde Supabase (asíncrona); mismo patrón que el resto del CRM.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar();
    const ch = supabase
      .channel("cocinar-deals")
      .on("postgres_changes", { event: "*", schema: "public", table: "deals" }, () => cargar())
      .subscribe();
    return () => {
      supabase.removeChannel(ch);
    };
  }, [supabase, cargar]);

  const dias = useMemo(() => {
    const s = new Set<string>([hoy, manana]);
    filas.forEach((f) => f.expected_close_date && s.add(f.expected_close_date));
    return [...s].sort();
  }, [filas, hoy, manana]);

  const { charolas, cuenta, extras, notas } = useMemo(() => {
    const cuenta: Record<string, number> = {};
    const extras: Record<string, number> = {};
    const notas: { quien: string; t: string }[] = [];
    let charolas = 0;
    filas
      .filter((f) => f.expected_close_date === dia)
      .forEach((f) => {
        const e = sumarEncargo(f.notes);
        charolas += e.charolas;
        for (const [k, v] of Object.entries(e.platos)) cuenta[k] = (cuenta[k] || 0) + v;
        for (const [k, v] of Object.entries(e.extras)) extras[k] = (extras[k] || 0) + v;
        for (const t of e.notas) notas.push({ quien: f.title, t });
      });
    return { charolas, cuenta, extras, notas };
  }, [filas, dia]);

  const conocidos = new Set(GRUPOS.flatMap(([, o]) => o));
  const otros = Object.keys(cuenta).filter((k) => !conocidos.has(k));

  if (cargando) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-4">
      <div className="flex gap-2 overflow-x-auto pb-1">
        {dias.map((d) => (
          <button
            key={d}
            type="button"
            onClick={() => setDia(d)}
            className={
              "shrink-0 rounded-full border px-4 py-2 text-sm font-semibold transition-colors " +
              (d === dia
                ? "border-primary bg-primary text-primary-foreground"
                : "border-border bg-card text-foreground hover:bg-muted")
            }
          >
            {etiqueta(d, hoy, manana)}
          </button>
        ))}
      </div>

      <p className="text-base text-muted-foreground">
        <span className="font-bold text-foreground">
          {charolas} {charolas === 1 ? "charola" : "charolas"}
        </span>{" "}
        para el {largo(dia)}
      </p>

      {charolas === 0 && Object.keys(extras).length === 0 ? (
        <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-border p-10 text-center text-muted-foreground">
          <ChefHat className="h-8 w-8" />
          No hay nada que cocinar ese día
        </div>
      ) : (
        <div className="rounded-xl border border-border bg-card px-4 pb-2">
          {[...GRUPOS, ["Otros", otros] as [string, string[]]].map(([titulo, ops]) => {
            const f = ops.filter((o) => cuenta[o]);
            if (!f.length) return null;
            return (
              <div key={titulo}>
                <h3 className="mt-4 mb-1 text-xs font-semibold uppercase tracking-wider text-muted-foreground">{titulo}</h3>
                {f.map((o) => (
                  <div key={o} className="flex items-center justify-between border-b border-border py-2.5 text-base last:border-0">
                    <span>{o}</span>
                    <b className="text-xl tabular-nums text-primary">{cuenta[o]}</b>
                  </div>
                ))}
              </div>
            );
          })}
          {Object.keys(extras).length > 0 && (
            <div>
              <h3 className="mt-4 mb-1 text-xs font-semibold uppercase tracking-wider text-muted-foreground">Extras</h3>
              {Object.entries(extras).map(([k, v]) => (
                <div key={k} className="flex items-center justify-between border-b border-border py-2.5 text-base last:border-0">
                  <span>{k}</span>
                  <b className="text-xl tabular-nums text-primary">{v}</b>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {notas.length > 0 && (
        <div className="rounded-xl border border-border bg-card p-4">
          <h3 className="mb-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground">Notas de los clientes</h3>
          <ul className="flex flex-col gap-1.5 text-base">
            {notas.map((n, i) => (
              <li key={i}>
                <b>{n.quien}:</b> {n.t}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
