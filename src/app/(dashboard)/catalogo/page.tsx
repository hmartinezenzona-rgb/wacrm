"use client";

// ============================================================
// Catálogo — edición AP Suministros.
//
// Las líneas de producto y servicio con las marcas que se manejan
// (tabla catalogo, migración 310). Es la única fuente: la página web y el
// bot de WhatsApp leen de aquí. Si una línea se apaga, el bot deja de
// ofrecerla. Cada cambio se guarda al salir del campo.
// ============================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { toast } from "sonner";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { Switch } from "@/components/ui/switch";

interface Linea {
  id: string;
  nombre: string;
  descripcion: string | null;
  marcas: string | null;
  disponible: boolean;
  orden: number;
}

function Campo({
  valor,
  placeholder,
  multilinea,
  className,
  onGuardar,
}: {
  valor: string;
  placeholder: string;
  multilinea?: boolean;
  className?: string;
  onGuardar: (v: string) => void;
}) {
  const [v, setV] = useState(valor);
  // Sincroniza cuando el valor guardado cambia desde fuera.
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => setV(valor), [valor]);
  const comun = {
    value: v,
    placeholder,
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => setV(e.target.value),
    onBlur: () => {
      if (v.trim() !== valor.trim()) onGuardar(v.trim());
    },
    className:
      "w-full rounded-lg border border-transparent bg-transparent px-2 py-1.5 outline-none hover:border-border focus:border-primary focus:bg-background " +
      (className ?? ""),
  };
  return multilinea ? <textarea rows={2} {...comun} /> : <input {...comun} />;
}

export default function CatalogoPage() {
  const supabase = useMemo(() => createClient(), []);
  const { account } = useAuth();
  const accountId = account?.id;
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [cargando, setCargando] = useState(true);
  const [nueva, setNueva] = useState("");
  const [borrando, setBorrando] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    if (!accountId) return;
    const { data } = await supabase
      .from("catalogo")
      .select("*")
      .eq("account_id", accountId)
      .order("orden")
      .order("nombre");
    setLineas((data as Linea[]) ?? []);
    setCargando(false);
  }, [supabase, accountId]);

  useEffect(() => {
    // Carga inicial desde Supabase (asíncrona); mismo patrón que el resto del CRM.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    cargar();
  }, [cargar]);

  async function guardar(id: string, cambio: Partial<Linea>, aviso = "Guardado") {
    setLineas((xs) => xs.map((x) => (x.id === id ? { ...x, ...cambio } : x)));
    const { error } = await supabase
      .from("catalogo")
      .update({ ...cambio, updated_at: new Date().toISOString() })
      .eq("id", id);
    if (error) {
      toast.error(error.code === "23505" ? "Ya hay una línea con ese nombre" : "No se pudo guardar");
      cargar();
    } else toast.success(aviso);
  }

  async function agregar() {
    const nombre = nueva.trim();
    if (!nombre || !accountId) return;
    const orden = Math.max(-1, ...lineas.map((x) => x.orden)) + 1;
    const { data, error } = await supabase
      .from("catalogo")
      .insert({ account_id: accountId, nombre, orden })
      .select()
      .single();
    if (error) {
      toast.error(error.code === "23505" ? "Esa línea ya está en el catálogo" : "No se pudo agregar");
      return;
    }
    setLineas((xs) => [...xs, data as Linea]);
    setNueva("");
    toast.success(`Agregado: ${nombre}`);
  }

  async function borrar(id: string) {
    const l = lineas.find((x) => x.id === id);
    setBorrando(null);
    setLineas((xs) => xs.filter((x) => x.id !== id));
    const { error } = await supabase.from("catalogo").delete().eq("id", id);
    if (error) {
      toast.error("No se pudo borrar");
      cargar();
    } else toast.success(`Borrado: ${l?.nombre ?? ""}`);
  }

  if (cargando || !accountId) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-4 pb-10">
      <p className="text-sm text-muted-foreground">
        Lo que aparece aquí es lo que el bot de WhatsApp y la página ofrecen. Apaga una línea si por ahora no la
        manejan. Los precios no van aquí: cada cotización lleva el suyo.
      </p>

      <ul className="flex flex-col gap-3">
        {lineas.map((l) => (
          <li key={l.id} className="rounded-xl border border-border bg-card p-3">
            <div className="flex items-start gap-3">
              <div className="min-w-0 flex-1">
                <Campo
                  valor={l.nombre}
                  placeholder="Nombre de la línea"
                  className={"text-base font-bold " + (l.disponible ? "" : "text-muted-foreground line-through")}
                  onGuardar={(v) => (v ? guardar(l.id, { nombre: v }) : cargar())}
                />
                <Campo
                  valor={l.descripcion ?? ""}
                  placeholder="Qué incluye (productos, medidas, servicios)"
                  multilinea
                  className="text-sm text-muted-foreground"
                  onGuardar={(v) => guardar(l.id, { descripcion: v || null })}
                />
                <div className="flex items-center gap-1 px-2">
                  <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Marcas</span>
                  <Campo
                    valor={l.marcas ?? ""}
                    placeholder="Ej. Fluke, Mitutoyo"
                    className="text-sm"
                    onGuardar={(v) => guardar(l.id, { marcas: v || null })}
                  />
                </div>
              </div>
              <div className="flex flex-col items-end gap-3 pt-1.5">
                <Switch
                  checked={l.disponible}
                  onCheckedChange={(v: boolean) =>
                    guardar(l.id, { disponible: v }, v ? `${l.nombre}: se ofrece` : `${l.nombre}: apagada`)
                  }
                  aria-label={`Ofrecer ${l.nombre}`}
                />
                {borrando === l.id ? (
                  <div className="flex gap-1">
                    <button
                      type="button"
                      onClick={() => borrar(l.id)}
                      className="rounded-md bg-destructive px-2 py-1 text-xs font-semibold text-white"
                    >
                      Borrar
                    </button>
                    <button
                      type="button"
                      onClick={() => setBorrando(null)}
                      className="rounded-md px-2 py-1 text-xs text-muted-foreground hover:bg-muted"
                    >
                      No
                    </button>
                  </div>
                ) : (
                  <button
                    type="button"
                    onClick={() => setBorrando(l.id)}
                    className="rounded-md p-1.5 text-muted-foreground hover:bg-muted hover:text-foreground"
                    aria-label={`Borrar ${l.nombre}`}
                  >
                    <Trash2 className="h-4 w-4" />
                  </button>
                )}
              </div>
            </div>
          </li>
        ))}
      </ul>

      <div className="flex gap-2">
        <input
          value={nueva}
          onChange={(e) => setNueva(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && agregar()}
          placeholder="Nueva línea de producto o servicio"
          className="h-11 min-w-0 flex-1 rounded-lg border border-border bg-background px-3 text-base outline-none focus:border-primary"
        />
        <button
          type="button"
          onClick={agregar}
          disabled={!nueva.trim()}
          className="flex h-11 items-center gap-1.5 rounded-lg bg-primary px-4 text-base font-semibold text-primary-foreground disabled:opacity-50"
        >
          <Plus className="h-4 w-4" /> Agregar
        </button>
      </div>
    </div>
  );
}
