"use client";

// ============================================================
// Qué cocinar — CRM base, configurable por negocio.
//
// Suma lo que hay que preparar un día a partir de los pedidos del
// tablero (deals con la entrega en `expected_close_date` y el detalle en
// `notes`, una línea por unidad: «Charola 1: Congrí, Ropa vieja»). Las
// partes (Arroz, Carne…) y la palabra («charola», «orden») salen de
// negocio_config.pedido; cada platillo se acomoda en su parte según
// menu_items. Las etapas con «cancel» no cuentan.
//
// Cada renglón se puede tachar al tenerlo listo. Lo tachado se guarda
// solo en este celular (es una ayuda de cocina, no un dato del negocio).
// ============================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { Check, ChefHat, Loader2 } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { useNegocio } from "@/hooks/use-negocio";
import { cuantas } from "@/lib/negocio/config";
import { diaCorto, diaLargo, isoLocal } from "@/lib/negocio/dias";
import { sumarEncargo } from "@/lib/encargos/leer";
import { cn } from "@/lib/utils";

interface Fila {
  id: string;
  title: string;
  notes: string | null;
  expected_close_date: string | null;
  stage: { name: string } | null;
  contact: { name: string | null } | null;
}

const LISTO_KEY = "wacrm.cocinar.listo";

function leerListos(): Record<string, string[]> {
  try {
    return JSON.parse(localStorage.getItem(LISTO_KEY) || "{}");
  } catch {
    return {};
  }
}

export default function CocinarPage() {
  const supabase = useMemo(() => createClient(), []);
  const { negocio } = useNegocio();
  const { uno, grupos } = negocio.pedido;
  const [{ hoy, manana }] = useState(() => {
    const ahora = new Date();
    return { hoy: isoLocal(ahora), manana: isoLocal(new Date(ahora.getTime() + 86400000)) };
  });
  const [filas, setFilas] = useState<Fila[]>([]);
  const [grupoDe, setGrupoDe] = useState<Record<string, string>>({});
  const [cargando, setCargando] = useState(true);
  const [dia, setDia] = useState(hoy);
  const [listos, setListos] = useState<Record<string, string[]>>({});

  const cargar = useCallback(async () => {
    const [d, m] = await Promise.all([
      supabase
        .from("deals")
        .select("id,title,notes,expected_close_date,stage:pipeline_stages(name),contact:contacts(name)")
        .gte("expected_close_date", hoy)
        .order("expected_close_date"),
      supabase.from("menu_items").select("nombre,grupo"),
    ]);
    setFilas(((d.data as unknown as Fila[]) || []).filter((f) => !/cancel/i.test(f.stage?.name || "")));
    const mapa: Record<string, string> = {};
    for (const x of (m.data as { nombre: string; grupo: string }[]) || []) mapa[x.nombre] = x.grupo;
    setGrupoDe(mapa);
    setCargando(false);
  }, [supabase, hoy]);

  useEffect(() => {
    // Carga inicial desde Supabase (asíncrona); mismo patrón que el resto del CRM.
    /* eslint-disable react-hooks/set-state-in-effect */
    setListos(leerListos());
    cargar();
    /* eslint-enable react-hooks/set-state-in-effect */
    const ch = supabase
      .channel("cocinar-deals")
      .on("postgres_changes", { event: "*", schema: "public", table: "deals" }, () => cargar())
      .subscribe();
    return () => {
      supabase.removeChannel(ch);
    };
  }, [supabase, cargar]);

  const otrosDias = useMemo(() => {
    const s = new Set<string>();
    filas.forEach((f) => f.expected_close_date && f.expected_close_date > manana && s.add(f.expected_close_date));
    return [...s].sort();
  }, [filas, manana]);

  const { total, partes, notas } = useMemo(() => {
    const cuenta: Record<string, number> = {};
    const extras: Record<string, number> = {};
    const notas: { quien: string; t: string }[] = [];
    let total = 0;
    for (const f of filas.filter((x) => x.expected_close_date === dia)) {
      const e = sumarEncargo(f.notes, uno);
      total += e.charolas;
      for (const [k, v] of Object.entries(e.platos)) cuenta[k] = (cuenta[k] || 0) + v;
      for (const [k, v] of Object.entries(e.extras)) extras[k] = (extras[k] || 0) + v;
      const quien = f.contact?.name || f.title.replace(/^\d+\s+\S+\s+·\s+/, "");
      for (const t of e.notas) notas.push({ quien, t });
    }
    // Acomoda cada platillo en su parte; lo que no está en el menú va a «Otros».
    const idsExtra = new Set(grupos.filter((g) => g.tipo === "extra").map((g) => g.id));
    const partes = grupos
      .map((g) => ({
        id: g.id,
        nombre: g.nombre,
        items: Object.entries(g.tipo === "extra" ? extras : cuenta)
          .filter(([k]) => (g.tipo === "extra" ? grupoDe[k] === g.id || (!grupoDe[k] && idsExtra.size === 1) : grupoDe[k] === g.id))
          .sort((a, b) => b[1] - a[1]),
      }))
      .filter((g) => g.items.length);
    const usados = new Set(partes.flatMap((g) => g.items.map(([k]) => k)));
    const sueltos = [...Object.entries(cuenta), ...Object.entries(extras)].filter(([k]) => !usados.has(k));
    if (sueltos.length) partes.push({ id: "__otros", nombre: "Otros", items: sueltos });
    return { total, partes, notas };
  }, [filas, dia, uno, grupos, grupoDe]);

  const renglones = partes.reduce((n, g) => n + g.items.length, 0);
  const tachados = new Set(listos[dia] ?? []);
  const hechos = partes.reduce((n, g) => n + g.items.filter(([k]) => tachados.has(`${g.id}:${k}`)).length, 0);

  function tachar(clave: string) {
    setListos((prev) => {
      const del = new Set(prev[dia] ?? []);
      if (del.has(clave)) del.delete(clave);
      else del.add(clave);
      // Solo se guardan los días que vienen, para no llenar el celular.
      const nuevo = Object.fromEntries(Object.entries({ ...prev, [dia]: [...del] }).filter(([d]) => d >= hoy));
      try {
        localStorage.setItem(LISTO_KEY, JSON.stringify(nuevo));
      } catch {
        // Sin localStorage el tachado dura hasta cerrar la pantalla.
      }
      return nuevo;
    });
  }

  if (cargando) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-primary" />
      </div>
    );
  }

  const pestana = (iso: string, titulo: string) => (
    <button
      key={iso}
      type="button"
      role="tab"
      aria-selected={dia === iso}
      onClick={() => setDia(iso)}
      className={cn(
        "flex min-h-16 flex-col items-center justify-center rounded-2xl px-3 leading-tight",
        dia === iso ? "bg-card text-foreground shadow-sm" : "text-muted-foreground",
      )}
    >
      <span className="text-lg font-extrabold">{titulo}</span>
      <span className="text-sm font-semibold">{diaCorto(iso)}</span>
    </button>
  );

  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-4">
      <div role="tablist" aria-label="Día" className="grid grid-cols-2 gap-1.5 rounded-3xl bg-muted p-1.5">
        {pestana(hoy, "Hoy")}
        {pestana(manana, "Mañana")}
      </div>
      {otrosDias.length > 0 && (
        <div className="flex gap-2 overflow-x-auto pb-1">
          <span className="shrink-0 self-center text-base font-semibold text-muted-foreground">Después:</span>
          {otrosDias.map((d) => (
            <button
              key={d}
              type="button"
              onClick={() => setDia(d)}
              className={cn(
                "min-h-11 shrink-0 rounded-full border-2 px-4 text-base font-bold",
                d === dia ? "border-primary bg-primary text-primary-foreground" : "border-border bg-card",
              )}
            >
              {diaCorto(d)}
            </button>
          ))}
        </div>
      )}

      <section className="flex items-center justify-between gap-3 rounded-3xl bg-primary p-5 text-primary-foreground">
        <div className="flex flex-col">
          <span className="text-base font-bold">Para el {diaLargo(dia)}</span>
          <span className="text-4xl font-extrabold leading-tight">{cuantas(negocio, total)}</span>
        </div>
        {renglones > 0 && (
          <div className="flex flex-col items-end">
            <span className="text-sm font-bold">Ya listo</span>
            <span className="text-2xl font-extrabold tabular-nums">
              {hechos} de {renglones}
            </span>
          </div>
        )}
      </section>

      {renglones === 0 ? (
        <div className="flex flex-col items-center gap-3 rounded-3xl border-2 border-dashed border-border p-10 text-center text-lg text-muted-foreground">
          <ChefHat className="h-9 w-9" aria-hidden />
          No hay nada que preparar ese día
        </div>
      ) : (
        <>
          <p className="px-1 text-base text-muted-foreground">Toca cada cosa cuando ya esté lista.</p>
          {partes.map((g) => (
            <section key={g.id} className="flex flex-col gap-2">
              <h2 className="px-1 text-2xl font-extrabold">{g.nombre}</h2>
              <div className="overflow-hidden rounded-3xl border-2 border-border bg-card">
                {g.items.map(([nombre, n]) => {
                  const clave = `${g.id}:${nombre}`;
                  const listo = tachados.has(clave);
                  return (
                    <button
                      key={nombre}
                      type="button"
                      aria-pressed={listo}
                      onClick={() => tachar(clave)}
                      className={cn(
                        "flex min-h-16 w-full items-center gap-4 border-t-2 border-border/60 px-4 py-2 text-left first:border-t-0",
                        listo && "bg-ok-soft",
                      )}
                    >
                      <span
                        aria-hidden
                        className={cn(
                          "flex h-9 w-9 shrink-0 items-center justify-center rounded-xl border-[3px]",
                          listo ? "border-ok bg-ok text-ok-foreground" : "border-input",
                        )}
                      >
                        {listo && <Check className="h-6 w-6" strokeWidth={3.2} />}
                      </span>
                      <span className={cn("flex-1 text-xl font-extrabold", listo && "text-muted-foreground line-through")}>
                        {nombre}
                      </span>
                      <span className={cn("text-3xl font-extrabold tabular-nums", listo ? "text-ok" : "text-primary")}>
                        ×{n}
                      </span>
                    </button>
                  );
                })}
              </div>
            </section>
          ))}
        </>
      )}

      {notas.length > 0 && (
        <section className="flex flex-col gap-2">
          <h2 className="px-1 text-2xl font-extrabold">Ojo con esto</h2>
          <div className="rounded-3xl border-2 border-pendiente/30 bg-pendiente-soft px-4">
            {notas.map((n, i) => (
              <div key={i} className="flex flex-col border-t-2 border-pendiente/20 py-3 first:border-t-0">
                <span className="text-base font-extrabold text-pendiente">{n.quien}</span>
                <span className="text-lg font-bold">{n.t}</span>
              </div>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
