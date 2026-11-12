"use client";

// ============================================================
// Menú — edición Doña Miriam.
//
// La única fuente del menú: la página web y el bot leen de aquí
// (menu_config + menu_items, migración 300). Miriam prende/apaga platos,
// elige en qué días se ofrece cada uno, cambia precios y el cupo diario.
// Cada cambio se guarda al momento.
// ============================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { toast } from "sonner";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { Switch } from "@/components/ui/switch";

type Grupo = "arroz" | "carne" | "vianda" | "potaje" | "extra";
interface Item {
  id: string;
  grupo: Grupo;
  nombre: string;
  precio: number | null;
  disponible: boolean;
  dias: number[] | null;
  orden: number;
}
interface Config {
  account_id: string;
  precio_charola: number;
  anticipo: number;
  cupo_diario: number;
  dias_entrega: number[];
  aviso: string | null;
}

const GRUPOS: { id: Grupo; titulo: string; ayuda?: string }[] = [
  { id: "arroz", titulo: "Arroz" },
  { id: "carne", titulo: "Carne" },
  { id: "vianda", titulo: "Vianda" },
  { id: "potaje", titulo: "Potaje", ayuda: "Opcional para el cliente" },
  { id: "extra", titulo: "Extras", ayuda: "Se cobran aparte" },
];
// Lunes primero, como piensa Miriam la semana.
const DIAS: { n: number; l: string }[] = [
  { n: 1, l: "L" }, { n: 2, l: "M" }, { n: 3, l: "M" }, { n: 4, l: "J" },
  { n: 5, l: "V" }, { n: 6, l: "S" }, { n: 0, l: "D" },
];

const MENU_INICIAL: Omit<Item, "id">[] = [
  ["arroz", ["Congrí", "Arroz blanco", "Arroz amarillo"]],
  ["carne", ["Fricasé de puerco", "Fricasé de pollo", "Bistec de puerco", "Ropa vieja", "Picadillo de res", "Chuleta de puerco"]],
  ["vianda", ["Papa con mojo", "Boniato", "Platanito maduro frito", "Tostones"]],
  ["potaje", ["Frijoles negros", "Frijoles colorados", "Chícharo"]],
].flatMap(([g, ops]) =>
  (ops as string[]).map((nombre, i): Omit<Item, "id"> => ({ grupo: g as Grupo, nombre, precio: null, disponible: true, dias: null, orden: i })),
).concat([
  { grupo: "extra", nombre: "Ración extra de arroz", precio: 40, disponible: true, dias: null, orden: 0 },
  { grupo: "extra", nombre: "Ración extra de potaje", precio: 40, disponible: true, dias: null, orden: 1 },
]);

function NumeroCampo({ label, valor, prefijo, onGuardar }: { label: string; valor: number; prefijo?: string; onGuardar: (n: number) => void }) {
  const [v, setV] = useState(String(valor));
  // Sincroniza el campo cuando el valor guardado cambia desde fuera.
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => setV(String(valor)), [valor]);
  return (
    <label className="flex flex-col gap-1">
      <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">{label}</span>
      <div className="flex items-center gap-1 rounded-lg border border-border bg-background px-3 focus-within:border-primary">
        {prefijo && <span className="text-muted-foreground">{prefijo}</span>}
        <input
          inputMode="decimal"
          className="h-11 w-full min-w-0 bg-transparent text-lg font-semibold tabular-nums outline-none"
          value={v}
          onChange={(e) => setV(e.target.value.replace(/[^\d.]/g, ""))}
          onBlur={() => {
            const n = Number(v);
            if (!Number.isFinite(n) || v === "") return setV(String(valor));
            if (n !== valor) onGuardar(n);
          }}
        />
      </div>
    </label>
  );
}

export default function MenuPage() {
  const supabase = useMemo(() => createClient(), []);
  const { account } = useAuth();
  const accountId = account?.id;
  const [config, setConfig] = useState<Config | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [cargando, setCargando] = useState(true);
  const [nuevo, setNuevo] = useState<Record<Grupo, string>>({ arroz: "", carne: "", vianda: "", potaje: "", extra: "" });
  const [borrando, setBorrando] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    if (!accountId) return;
    const [c, i] = await Promise.all([
      supabase.from("menu_config").select("*").eq("account_id", accountId).maybeSingle(),
      supabase.from("menu_items").select("*").eq("account_id", accountId).order("orden").order("nombre"),
    ]);
    setConfig((c.data as Config) ?? null);
    setItems((i.data as Item[]) ?? []);
    setCargando(false);
  }, [supabase, accountId]);

  useEffect(() => {
    // Carga inicial desde Supabase (asíncrona); mismo patrón que el resto del CRM.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar();
  }, [cargar]);

  async function crearMenuInicial() {
    if (!accountId) return;
    setCargando(true);
    const a = await supabase.from("menu_config").upsert({ account_id: accountId });
    const b = await supabase.from("menu_items").upsert(
      MENU_INICIAL.map((x) => ({ ...x, account_id: accountId })),
      { onConflict: "account_id,grupo,nombre", ignoreDuplicates: true },
    );
    if (a.error || b.error) toast.error("No se pudo crear el menú");
    await cargar();
  }

  async function guardarConfig(cambio: Partial<Config>) {
    if (!config) return;
    setConfig({ ...config, ...cambio });
    const { error } = await supabase
      .from("menu_config")
      .update({ ...cambio, updated_at: new Date().toISOString() })
      .eq("account_id", config.account_id);
    if (error) {
      toast.error("No se pudo guardar");
      cargar();
    } else toast.success("Guardado");
  }

  async function guardarItem(id: string, cambio: Partial<Item>, aviso?: string) {
    setItems((xs) => xs.map((x) => (x.id === id ? { ...x, ...cambio } : x)));
    const { error } = await supabase
      .from("menu_items")
      .update({ ...cambio, updated_at: new Date().toISOString() })
      .eq("id", id);
    if (error) {
      toast.error("No se pudo guardar");
      cargar();
    } else if (aviso) toast.success(aviso);
  }

  async function agregar(grupo: Grupo) {
    const nombre = nuevo[grupo].trim();
    if (!nombre || !accountId) return;
    const orden = Math.max(-1, ...items.filter((x) => x.grupo === grupo).map((x) => x.orden)) + 1;
    const { data, error } = await supabase
      .from("menu_items")
      .insert({ account_id: accountId, grupo, nombre, orden, precio: grupo === "extra" ? 40 : null })
      .select()
      .single();
    if (error) {
      toast.error(error.code === "23505" ? "Ese plato ya está en el menú" : "No se pudo agregar");
      return;
    }
    setItems((xs) => [...xs, data as Item]);
    setNuevo((n) => ({ ...n, [grupo]: "" }));
    toast.success(`Agregado: ${nombre}`);
  }

  async function borrar(id: string) {
    const it = items.find((x) => x.id === id);
    setBorrando(null);
    setItems((xs) => xs.filter((x) => x.id !== id));
    const { error } = await supabase.from("menu_items").delete().eq("id", id);
    if (error) {
      toast.error("No se pudo borrar");
      cargar();
    } else toast.success(`Borrado: ${it?.nombre ?? ""}`);
  }

  function toggleDia(it: Item, n: number) {
    const base = it.dias ?? DIAS.map((d) => d.n);
    let dias = base.includes(n) ? base.filter((d) => d !== n) : [...base, n];
    if (dias.length === 0) return toast.error("Si no se ofrece ningún día, mejor apágalo");
    if (dias.length === 7) dias = [];
    guardarItem(it.id, { dias: dias.length ? dias : null });
  }

  if (cargando || !accountId) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-primary" />
      </div>
    );
  }

  if (!config) {
    return (
      <div className="mx-auto flex max-w-md flex-col items-center gap-4 rounded-xl border border-dashed border-border p-8 text-center">
        <p className="text-base text-muted-foreground">Todavía no hay menú.</p>
        <button
          type="button"
          onClick={crearMenuInicial}
          className="h-12 rounded-lg bg-primary px-6 text-base font-semibold text-primary-foreground"
        >
          Crear el menú de la charola
        </button>
      </div>
    );
  }

  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-5 pb-10">
      <section className="rounded-xl border border-border bg-card p-4">
        <h2 className="mb-3 text-base font-bold">La charola</h2>
        <div className="grid grid-cols-3 gap-3">
          <NumeroCampo label="Precio" prefijo="$" valor={Number(config.precio_charola)} onGuardar={(n) => guardarConfig({ precio_charola: n })} />
          <NumeroCampo label="Anticipo" prefijo="$" valor={Number(config.anticipo)} onGuardar={(n) => guardarConfig({ anticipo: n })} />
          <NumeroCampo label="Cupo por día" valor={config.cupo_diario} onGuardar={(n) => guardarConfig({ cupo_diario: Math.round(n) })} />
        </div>
        <div className="mt-4">
          <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Días que entrego</span>
          <div className="mt-1.5 flex flex-wrap gap-2">
            {DIAS.map((d, i) => {
              const on = config.dias_entrega.includes(d.n);
              return (
                <button
                  key={i}
                  type="button"
                  onClick={() =>
                    guardarConfig({
                      dias_entrega: on ? config.dias_entrega.filter((x) => x !== d.n) : [...config.dias_entrega, d.n].sort(),
                    })
                  }
                  className={
                    "h-11 w-11 rounded-full border text-base font-bold " +
                    (on ? "border-primary bg-primary text-primary-foreground" : "border-border text-muted-foreground")
                  }
                  aria-pressed={on}
                >
                  {d.l}
                </button>
              );
            })}
          </div>
        </div>
      </section>

      {GRUPOS.map((g) => {
        const lista = items.filter((x) => x.grupo === g.id).sort((a, b) => a.orden - b.orden);
        return (
          <section key={g.id} className="rounded-xl border border-border bg-card p-4">
            <div className="mb-2 flex items-baseline justify-between gap-2">
              <h2 className="text-base font-bold">{g.titulo}</h2>
              {g.ayuda && <span className="text-sm text-muted-foreground">{g.ayuda}</span>}
            </div>
            <ul className="flex flex-col">
              {lista.map((it) => (
                <li key={it.id} className="flex flex-col gap-2 border-b border-border py-3 last:border-0">
                  <div className="flex items-center gap-3">
                    <span className={"min-w-0 flex-1 text-base " + (it.disponible ? "" : "text-muted-foreground line-through")}>
                      {it.nombre}
                    </span>
                    {g.id === "extra" && (
                      <div className="w-24">
                        <NumeroCampo
                          label=""
                          prefijo="$"
                          valor={Number(it.precio ?? 0)}
                          onGuardar={(n) => guardarItem(it.id, { precio: n }, "Precio guardado")}
                        />
                      </div>
                    )}
                    <Switch
                      checked={it.disponible}
                      onCheckedChange={(v: boolean) =>
                        guardarItem(it.id, { disponible: v }, v ? `${it.nombre}: hay` : `${it.nombre}: no hay`)
                      }
                      aria-label={`Hay ${it.nombre}`}
                    />
                  </div>
                  <div className="flex items-center gap-1.5">
                    {DIAS.map((d, i) => {
                      const on = !it.dias || it.dias.includes(d.n);
                      return (
                        <button
                          key={i}
                          type="button"
                          onClick={() => toggleDia(it, d.n)}
                          className={
                            "h-8 w-8 rounded-full text-xs font-bold " +
                            (on ? "bg-primary/15 text-primary" : "bg-muted text-muted-foreground/60 line-through")
                          }
                          aria-pressed={on}
                          aria-label={`${it.nombre} el día ${d.l}`}
                        >
                          {d.l}
                        </button>
                      );
                    })}
                    <span className="flex-1" />
                    {borrando === it.id ? (
                      <span className="flex items-center gap-2">
                        <button type="button" onClick={() => setBorrando(null)} className="h-8 rounded-md px-2 text-sm text-muted-foreground">
                          No
                        </button>
                        <button type="button" onClick={() => borrar(it.id)} className="h-8 rounded-md bg-destructive px-3 text-sm font-semibold text-white">
                          Sí, borrar
                        </button>
                      </span>
                    ) : (
                      <button
                        type="button"
                        onClick={() => setBorrando(it.id)}
                        className="flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground hover:bg-muted"
                        aria-label={`Borrar ${it.nombre}`}
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    )}
                  </div>
                </li>
              ))}
            </ul>
            <form
              className="mt-2 flex gap-2"
              onSubmit={(e) => {
                e.preventDefault();
                agregar(g.id);
              }}
            >
              <input
                className="h-11 min-w-0 flex-1 rounded-lg border border-border bg-background px-3 text-base outline-none focus:border-primary"
                placeholder={`Agregar a ${g.titulo.toLowerCase()}…`}
                value={nuevo[g.id]}
                onChange={(e) => setNuevo((n) => ({ ...n, [g.id]: e.target.value }))}
              />
              <button type="submit" className="flex h-11 w-11 items-center justify-center rounded-lg bg-primary text-primary-foreground" aria-label="Agregar">
                <Plus className="h-5 w-5" />
              </button>
            </form>
          </section>
        );
      })}
    </div>
  );
}
