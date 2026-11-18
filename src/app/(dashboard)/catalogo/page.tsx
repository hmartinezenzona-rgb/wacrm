"use client";

// ============================================================
// Paquetes — edición Onlinefreedom (sale del catálogo de AP).
//
// Los paquetes con su precio y lo que incluyen (tabla catalogo,
// migraciones 310 y 320; «marcas» guarda lo que incluye, separado por «;»). Es la única fuente: la página web y el
// bot de WhatsApp leen de aquí. Si una línea se apaga, el bot deja de
// ofrecerla.
//
// Diseño tipo lista de productos (Pipedrive/HubSpot): una fila por línea
// con interruptor, nombre, descripción corta y marcas como etiquetas.
// Al tocar una fila se abre para editarla ahí mismo. Nombre y descripción
// se guardan al salir del campo; las marcas al agregarlas o quitarlas.
// ============================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { toast } from "sonner";
import { ChevronDown, Loader2, Plus, Search, Trash2, X } from "lucide-react";
import { Switch } from "@/components/ui/switch";

interface Linea {
  id: string;
  nombre: string;
  descripcion: string | null;
  marcas: string | null;
  precio: string | null;
  disponible: boolean;
  orden: number;
}

const separarMarcas = (m: string | null) =>
  (m ?? "")
    .split(";")
    .map((x) => x.trim())
    .filter(Boolean);

function Campo({
  valor,
  placeholder,
  multilinea,
  className,
  autoFocus,
  onGuardar,
}: {
  valor: string;
  placeholder: string;
  multilinea?: boolean;
  className?: string;
  autoFocus?: boolean;
  onGuardar: (v: string) => void;
}) {
  const [v, setV] = useState(valor);
  // Sincroniza cuando el valor guardado cambia desde fuera.
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => setV(valor), [valor]);
  const comun = {
    value: v,
    placeholder,
    autoFocus,
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => setV(e.target.value),
    onBlur: () => {
      if (v.trim() !== valor.trim()) onGuardar(v.trim());
    },
    className:
      "w-full rounded-md border border-border bg-background px-3 py-2 text-sm outline-none focus:border-primary " +
      (className ?? ""),
  };
  return multilinea ? <textarea rows={3} {...comun} /> : <input {...comun} />;
}

/** Marcas como etiquetas: Enter o coma agrega, la X quita. */
function EditorMarcas({ marcas, onCambiar }: { marcas: string[]; onCambiar: (m: string[]) => void }) {
  const [texto, setTexto] = useState("");
  function agregar() {
    const nuevas = texto
      .split(";")
      .map((x) => x.trim())
      .filter(Boolean)
      .filter((x) => !marcas.some((m) => m.toLowerCase() === x.toLowerCase()));
    setTexto("");
    if (nuevas.length) onCambiar([...marcas, ...nuevas]);
  }
  return (
    <div className="flex min-h-10 flex-wrap items-center gap-1.5 rounded-md border border-border bg-background px-2 py-1.5 focus-within:border-primary">
      {marcas.map((m) => (
        <span
          key={m}
          className="inline-flex items-center gap-1 rounded-md bg-primary/10 py-0.5 pl-2 pr-1 text-xs font-medium text-primary"
        >
          {m}
          <button
            type="button"
            onClick={() => onCambiar(marcas.filter((x) => x !== m))}
            className="rounded p-0.5 hover:bg-primary/20"
            aria-label={`Quitar ${m}`}
          >
            <X className="h-3 w-3" />
          </button>
        </span>
      ))}
      <input
        value={texto}
        onChange={(e) => setTexto(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === ";") {
            e.preventDefault();
            agregar();
          } else if (e.key === "Backspace" && !texto && marcas.length) {
            onCambiar(marcas.slice(0, -1));
          }
        }}
        onBlur={agregar}
        placeholder={marcas.length ? "Agregar otra cosa que incluye" : "Ej. Sitio web con tu dominio (Enter para agregar)"}
        className="h-7 min-w-[140px] flex-1 bg-transparent text-sm outline-none"
      />
    </div>
  );
}

export default function CatalogoPage() {
  const supabase = useMemo(() => createClient(), []);
  const { account } = useAuth();
  const accountId = account?.id;
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [cargando, setCargando] = useState(true);
  const [abierta, setAbierta] = useState<string | null>(null);
  const [borrando, setBorrando] = useState<string | null>(null);
  const [buscar, setBuscar] = useState("");
  const [nueva, setNueva] = useState<string | null>(null);

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
      toast.error(error.code === "23505" ? "Ya hay un paquete con ese nombre" : "No se pudo guardar");
      cargar();
    } else toast.success(aviso);
  }

  async function agregar() {
    const nombre = (nueva ?? "").trim();
    if (!nombre || !accountId) return;
    const orden = Math.max(-1, ...lineas.map((x) => x.orden)) + 1;
    const { data, error } = await supabase
      .from("catalogo")
      .insert({ account_id: accountId, nombre, orden })
      .select()
      .single();
    if (error) {
      toast.error(error.code === "23505" ? "Ese paquete ya existe" : "No se pudo agregar");
      return;
    }
    setLineas((xs) => [...xs, data as Linea]);
    setNueva(null);
    setAbierta((data as Linea).id);
    toast.success(`Agregado: ${nombre}`);
  }

  async function borrar(id: string) {
    const l = lineas.find((x) => x.id === id);
    setBorrando(null);
    setAbierta(null);
    setLineas((xs) => xs.filter((x) => x.id !== id));
    const { error } = await supabase.from("catalogo").delete().eq("id", id);
    if (error) {
      toast.error("No se pudo borrar");
      cargar();
    } else toast.success(`Borrado: ${l?.nombre ?? ""}`);
  }

  const q = buscar.trim().toLowerCase();
  const visibles = q
    ? lineas.filter((l) =>
        [l.nombre, l.descripcion ?? "", l.marcas ?? "", l.precio ?? ""].some((x) => x.toLowerCase().includes(q)),
      )
    : lineas;
  const activas = lineas.filter((l) => l.disponible).length;

  if (cargando || !accountId) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="mx-auto flex max-w-5xl flex-col gap-4 pb-10">
      {/* Resumen y acciones */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div className="min-w-0 flex-1">
          <p className="text-sm text-muted-foreground">
            Lo que el agente de WhatsApp ofrece, con su precio. Si cambias un precio aquí, el agente lo dice así desde
            el siguiente mensaje. Apaga un paquete si por ahora no lo vendes.
          </p>
          <p className="mt-1 text-xs tabular-nums text-muted-foreground">
            <span className="font-semibold text-foreground">{lineas.length}</span> paquetes ·{" "}
            <span className="font-semibold text-foreground">{activas}</span> se ofrecen
          </p>
        </div>
        <div className="flex gap-2">
          <div className="relative flex-1 sm:w-64 sm:flex-none">
            <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <input
              value={buscar}
              onChange={(e) => setBuscar(e.target.value)}
              placeholder="Buscar paquete"
              className="h-9 w-full rounded-md border border-border bg-background pl-8 pr-3 text-sm outline-none focus:border-primary"
            />
          </div>
          <button
            type="button"
            onClick={() => setNueva("")}
            className="flex h-9 shrink-0 items-center gap-1.5 rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground hover:bg-primary/90"
          >
            <Plus className="h-4 w-4" /> Nuevo paquete
          </button>
        </div>
      </div>

      <div className="overflow-hidden rounded-xl border border-border bg-card">
        {/* Encabezado de la lista (solo escritorio) */}
        <div className="hidden grid-cols-[52px_minmax(0,1.3fr)_minmax(0,1fr)_32px] items-center gap-3 border-b border-border bg-muted/40 px-4 py-2 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground md:grid">
          <span>Activo</span>
          <span>Paquete</span>
          <span>Precio</span>
          <span />
        </div>

        {nueva !== null && (
          <div className="flex gap-2 border-b border-border bg-primary/5 px-4 py-3">
            <input
              autoFocus
              value={nueva}
              onChange={(e) => setNueva(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") agregar();
                if (e.key === "Escape") setNueva(null);
              }}
              placeholder="Nombre del nuevo paquete (ej. Solo agente de IA)"
              className="h-9 min-w-0 flex-1 rounded-md border border-border bg-background px-3 text-sm outline-none focus:border-primary"
            />
            <button
              type="button"
              onClick={agregar}
              disabled={!nueva.trim()}
              className="h-9 rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground disabled:opacity-50"
            >
              Agregar
            </button>
            <button
              type="button"
              onClick={() => setNueva(null)}
              className="h-9 rounded-md px-3 text-sm text-muted-foreground hover:bg-muted"
            >
              Cancelar
            </button>
          </div>
        )}

        {visibles.length === 0 && (
          <p className="px-4 py-10 text-center text-sm text-muted-foreground">
            {q ? "Nada coincide con la búsqueda." : "Todavía no hay paquetes."}
          </p>
        )}

        <ul className="divide-y divide-border">
          {visibles.map((l) => {
            const marcas = separarMarcas(l.marcas);
            const open = abierta === l.id;
            return (
              <li key={l.id} className={open ? "bg-muted/30" : ""}>
                {/* Fila */}
                <div
                  className={`grid cursor-pointer grid-cols-[44px_minmax(0,1fr)_28px] items-start gap-3 px-4 py-3 hover:bg-muted/30 md:grid-cols-[52px_minmax(0,1.3fr)_minmax(0,1fr)_32px] md:items-center ${
                    l.disponible ? "" : "opacity-55"
                  }`}
                  onClick={() => setAbierta(open ? null : l.id)}
                >
                  <div onClick={(e) => e.stopPropagation()} className="pt-0.5 md:pt-0">
                    <Switch
                      checked={l.disponible}
                      onCheckedChange={(v: boolean) =>
                        guardar(l.id, { disponible: v }, v ? `${l.nombre}: se ofrece` : `${l.nombre}: apagado`)
                      }
                      aria-label={`Ofrecer ${l.nombre}`}
                    />
                  </div>
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="truncate text-sm font-semibold text-foreground">{l.nombre}</span>
                      {!l.disponible && (
                        <span className="shrink-0 rounded bg-muted px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground">
                          Apagado
                        </span>
                      )}
                    </div>
                    <p className="mt-0.5 line-clamp-1 text-xs text-muted-foreground">
                      {l.descripcion || "Sin descripción"}
                    </p>
                    {/* Precio en celular, debajo */}
                    {l.precio && (
                      <p className="mt-1 text-xs font-semibold text-foreground/90 md:hidden">{l.precio}</p>
                    )}
                  </div>
                  <div className="hidden text-sm font-semibold text-foreground/90 md:block">
                    {l.precio || <span className="text-xs font-normal text-muted-foreground/60">—</span>}
                  </div>
                  <ChevronDown
                    className={`mt-1 h-4 w-4 justify-self-end text-muted-foreground transition-transform md:mt-0 ${
                      open ? "rotate-180" : ""
                    }`}
                  />
                </div>

                {/* Edición en la misma fila */}
                {open && (
                  <div className="grid gap-3 px-4 pb-4 md:grid-cols-2 md:pl-[84px]">
                    <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
                      Nombre
                      <Campo
                        valor={l.nombre}
                        placeholder="Nombre del paquete"
                        className="font-semibold text-foreground"
                        onGuardar={(v) => (v ? guardar(l.id, { nombre: v }) : cargar())}
                      />
                    </label>
                    <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground md:row-span-2">
                      Para quién es
                      <Campo
                        valor={l.descripcion ?? ""}
                        placeholder="Una frase corta: para qué le sirve al cliente"
                        multilinea
                        className="text-foreground"
                        onGuardar={(v) => guardar(l.id, { descripcion: v || null })}
                      />
                    </label>
                    <div className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
                      Precio
                      <Campo
                        valor={l.precio ?? ""}
                        placeholder="Ej. $2,500 instalación + $299 al mes"
                        className="text-foreground"
                        onGuardar={(v) => guardar(l.id, { precio: v || null })}
                      />
                    </div>
                    <div className="flex flex-col gap-1 text-xs font-medium text-muted-foreground md:col-span-2">
                      Incluye
                      <EditorMarcas
                        marcas={marcas}
                        onCambiar={(m) => guardar(l.id, { marcas: m.length ? m.join("; ") : null })}
                      />
                    </div>
                    <div className="flex items-center justify-end gap-2 md:col-span-2">
                      {borrando === l.id ? (
                        <>
                          <span className="text-xs text-muted-foreground">¿Borrar «{l.nombre}»?</span>
                          <button
                            type="button"
                            onClick={() => borrar(l.id)}
                            className="h-8 rounded-md bg-destructive px-3 text-xs font-semibold text-white"
                          >
                            Sí, borrar
                          </button>
                          <button
                            type="button"
                            onClick={() => setBorrando(null)}
                            className="h-8 rounded-md px-3 text-xs text-muted-foreground hover:bg-muted"
                          >
                            No
                          </button>
                        </>
                      ) : (
                        <button
                          type="button"
                          onClick={() => setBorrando(l.id)}
                          className="flex h-8 items-center gap-1.5 rounded-md px-2 text-xs text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
                        >
                          <Trash2 className="h-3.5 w-3.5" /> Borrar paquete
                        </button>
                      )}
                      <button
                        type="button"
                        onClick={() => setAbierta(null)}
                        className="h-8 rounded-md border border-border px-3 text-xs font-medium hover:bg-muted"
                      >
                        Listo
                      </button>
                    </div>
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      </div>
    </div>
  );
}
