"use client";

// ============================================================
// Menú — CRM base, configurable por negocio.
//
// La única fuente de lo que se vende: la página web y el bot leen de aquí
// (menu_config + menu_items, migraciones 300 y 336). Las partes de cada
// pedido (Arroz, Carne… o Tacos, Salsas…) y las palabras («charola»,
// «orden») vienen de negocio_config.pedido; nada de eso está en el código.
//
// Pensado para el dueño en su celular (estilo Uber Eats / Square, con
// las guías para personas mayores): cada platillo es una fila grande
// con un solo botón «Hay» / «Agotado». Al marcar agotado pregunta
// «¿Hasta cuándo?»: solo hoy (agotado_hasta = hoy, vuelve solo mañana)
// o hasta que lo vuelva a prender (disponible = false). Lo demás
// (nombre, parte, días, precio, foto) se cambia tocando el platillo.
// Precio, anticipo y cupo se cambian con botones de menos y más.
// ============================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { Check, Info, Loader2, Minus, Plus, Trash2 } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { useNegocio } from "@/hooks/use-negocio";
import { capital, type GrupoPedido } from "@/lib/negocio/config";
import { SEMANA, diaCorto, isoLocal, resumenDias } from "@/lib/negocio/dias";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { cn } from "@/lib/utils";

interface Item {
  id: string;
  grupo: string;
  nombre: string;
  precio: number | null;
  disponible: boolean;
  agotado_hasta: string | null;
  dias: number[] | null;
  orden: number;
  foto_url: string | null;
}
interface Config {
  account_id: string;
  precio_charola: number;
  anticipo: number;
  cupo_diario: number;
  dias_entrega: number[];
}

const TODOS = SEMANA.map((d) => d.n);

/** Hay hoy: prendido y no agotado solo por hoy. */
function hayHoy(it: Item, hoy: string) {
  return it.disponible && !(it.agotado_hasta && it.agotado_hasta >= hoy);
}

// ---------- piezas ----------

function BotonGrande({
  children,
  onClick,
  variante = "primario",
  className,
  disabled,
  type = "button",
}: {
  children: React.ReactNode;
  onClick?: () => void;
  variante?: "primario" | "borde" | "texto";
  className?: string;
  disabled?: boolean;
  type?: "button" | "submit";
}) {
  return (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled}
      className={cn(
        "flex min-h-14 items-center justify-center gap-2 rounded-2xl px-5 text-lg font-bold transition-transform active:scale-[0.98] disabled:opacity-50",
        variante === "primario" && "bg-primary text-primary-foreground",
        variante === "borde" && "border-2 border-border bg-card text-foreground",
        variante === "texto" && "min-h-12 text-base underline underline-offset-4",
        className,
      )}
    >
      {children}
    </button>
  );
}

function Hoja({
  abierta,
  onCerrar,
  titulo,
  descripcion,
  children,
}: {
  abierta: boolean;
  onCerrar: () => void;
  titulo: string;
  descripcion?: string;
  children: React.ReactNode;
}) {
  return (
    <Sheet open={abierta} onOpenChange={(v) => !v && onCerrar()}>
      <SheetContent
        side="bottom"
        className="mx-auto max-h-[92dvh] w-full max-w-lg overflow-y-auto rounded-t-3xl border-x border-border pb-[max(1.25rem,env(safe-area-inset-bottom))]"
      >
        <div aria-hidden className="mx-auto mt-3 h-1.5 w-12 rounded-full bg-border" />
        <SheetHeader className="px-5 pb-0 pt-1">
          <SheetTitle className="pr-10 text-2xl font-extrabold">{titulo}</SheetTitle>
          {descripcion ? <SheetDescription className="text-base">{descripcion}</SheetDescription> : null}
        </SheetHeader>
        <div className="flex flex-col gap-5 px-5">{children}</div>
      </SheetContent>
    </Sheet>
  );
}

function Pasos({
  titulo,
  ayuda,
  texto,
  onMenos,
  onMas,
}: {
  titulo: string;
  ayuda: string;
  texto: string;
  onMenos: () => void;
  onMas: () => void;
}) {
  return (
    <section className="flex flex-col gap-2 rounded-2xl border-2 border-border bg-card p-4">
      <div>
        <h3 className="text-lg font-extrabold">{titulo}</h3>
        <p className="text-[15px] text-muted-foreground">{ayuda}</p>
      </div>
      <div className="flex items-center gap-3">
        <button
          type="button"
          onClick={onMenos}
          aria-label={`Bajar ${titulo.toLowerCase()}`}
          className="flex h-16 w-16 shrink-0 items-center justify-center rounded-2xl border-2 border-input bg-background active:scale-95"
        >
          <Minus className="h-7 w-7" strokeWidth={3} />
        </button>
        <span className="flex-1 text-center text-4xl font-extrabold tabular-nums" aria-live="polite">
          {texto}
        </span>
        <button
          type="button"
          onClick={onMas}
          aria-label={`Subir ${titulo.toLowerCase()}`}
          className="flex h-16 w-16 shrink-0 items-center justify-center rounded-2xl bg-primary text-primary-foreground active:scale-95"
        >
          <Plus className="h-7 w-7" strokeWidth={3} />
        </button>
      </div>
    </section>
  );
}

function ElegirDias({ dias, onCambio, verde = true }: { dias: number[]; onCambio: (d: number[]) => void; verde?: boolean }) {
  return (
    <div className="grid grid-cols-4 gap-2">
      {SEMANA.map((d) => {
        const on = dias.includes(d.n);
        return (
          <button
            key={d.n}
            type="button"
            aria-pressed={on}
            aria-label={`${capital(d.largo)}: ${on ? "sí" : "no"}`}
            onClick={() => onCambio(on ? dias.filter((x) => x !== d.n) : [...dias, d.n])}
            className={cn(
              "h-14 rounded-2xl border-2 text-lg font-extrabold",
              on
                ? verde
                  ? "border-ok bg-ok text-ok-foreground"
                  : "border-primary bg-primary text-primary-foreground"
                : "border-input bg-card text-muted-foreground",
            )}
          >
            {d.corto}
          </button>
        );
      })}
    </div>
  );
}

function Miniatura({ it, grande }: { it: Pick<Item, "nombre" | "foto_url">; grande?: boolean }) {
  const tam = grande ? "h-16 w-16 text-2xl" : "h-14 w-14 text-xl";
  if (it.foto_url) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={it.foto_url} alt="" className={cn(tam, "shrink-0 rounded-2xl object-cover")} />;
  }
  return (
    <span
      aria-hidden
      className={cn(tam, "flex shrink-0 items-center justify-center rounded-2xl bg-primary-soft-2 font-extrabold text-primary")}
    >
      {it.nombre.trim().charAt(0).toUpperCase() || "?"}
    </span>
  );
}

// ---------- página ----------

type Edicion = { tipo: "nuevo"; grupo: string } | { tipo: "item"; item: Item };

export default function MenuPage() {
  const supabase = useMemo(() => createClient(), []);
  const { account } = useAuth();
  const { negocio } = useNegocio();
  const accountId = account?.id;
  const { uno, varios, grupos } = negocio.pedido;
  const [hoy] = useState(() => isoLocal(new Date()));

  const [config, setConfig] = useState<Config | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [cargando, setCargando] = useState(true);
  const [hojaUnidad, setHojaUnidad] = useState(false);
  const [agotar, setAgotar] = useState<Item | null>(null);
  const [edicion, setEdicion] = useState<Edicion | null>(null);

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

  // Grupos del negocio + «Otros» para platillos de un grupo que ya no existe.
  const secciones = useMemo(() => {
    const ids = new Set(grupos.map((g) => g.id));
    const huerfanos = items.filter((x) => !ids.has(x.grupo));
    const lista: (GrupoPedido & { items: Item[] })[] = grupos.map((g) => ({
      ...g,
      items: items.filter((x) => x.grupo === g.id).sort((a, b) => a.orden - b.orden || a.nombre.localeCompare(b.nombre)),
    }));
    if (huerfanos.length) lista.push({ id: "__otros", nombre: "Otros", tipo: "uno", items: huerfanos });
    return lista;
  }, [grupos, items]);

  const totalHay = items.filter((x) => hayHoy(x, hoy)).length;
  const totalAgotado = items.filter((x) => !hayHoy(x, hoy)).length;

  async function guardarItem(id: string, cambio: Partial<Item>, aviso?: string) {
    const antes = items;
    setItems((xs) => xs.map((x) => (x.id === id ? { ...x, ...cambio } : x)));
    const { error } = await supabase
      .from("menu_items")
      .update({ ...cambio, updated_at: new Date().toISOString() })
      .eq("id", id);
    if (error) {
      setItems(antes);
      toast.error("No se pudo guardar. Revisa el internet e intenta otra vez.");
      return false;
    }
    if (aviso) toast.success(aviso);
    return true;
  }

  async function crearMenu() {
    if (!accountId) return;
    setCargando(true);
    const { error } = await supabase.from("menu_config").upsert({ account_id: accountId });
    if (error) toast.error("No se pudo crear el menú");
    await cargar();
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
      <div className="mx-auto flex max-w-md flex-col items-center gap-4 rounded-3xl border-2 border-dashed border-border p-8 text-center">
        <p className="text-lg text-muted-foreground">Todavía no hay menú.</p>
        <BotonGrande onClick={crearMenu}>Crear el menú</BotonGrande>
      </div>
    );
  }

  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-5">
      <p className="-mb-2 text-lg font-bold text-muted-foreground">Hoy, {diaCorto(hoy)}</p>

      {/* La unidad que se vende: precio, anticipo y cupo */}
      <section className="flex flex-col gap-3 rounded-3xl bg-primary p-5 text-primary-foreground">
        <div className="flex items-center justify-between gap-3">
          <h2 className="text-2xl font-extrabold">{capital(uno)}</h2>
          <button
            type="button"
            onClick={() => setHojaUnidad(true)}
            className="min-h-12 rounded-full bg-card px-5 text-lg font-extrabold text-primary active:scale-95"
          >
            Cambiar
          </button>
        </div>
        <div className="grid grid-cols-3 gap-2">
          {[
            ["Precio", `$${Number(config.precio_charola)}`],
            ["Anticipo", Number(config.anticipo) > 0 ? `$${Number(config.anticipo)}` : "No"],
            ["Al día", String(config.cupo_diario)],
          ].map(([t, v]) => (
            <div key={t} className="flex flex-col rounded-2xl bg-white/15 px-3 py-2">
              <span className="text-sm font-bold">{t}</span>
              <span className="text-2xl font-extrabold tabular-nums">{v}</span>
            </div>
          ))}
        </div>
        <p className="text-base font-semibold">Entrega: {resumenDias(config.dias_entrega).toLowerCase()}</p>
      </section>

      <div className="flex items-start gap-3 rounded-2xl border-2 border-border bg-card p-4">
        <Check className="mt-0.5 h-6 w-6 shrink-0 text-ok" strokeWidth={2.6} aria-hidden />
        <p className="text-lg font-bold leading-snug">
          Hoy se ofrecen {totalHay} {totalHay === 1 ? "platillo" : "platillos"}
          {totalAgotado > 0 && (
            <span className="text-primary">
              {" "}
              · {totalAgotado} {totalAgotado === 1 ? "agotado" : "agotados"}
            </span>
          )}
        </p>
      </div>
      <p className="-mt-2 px-1 text-base text-muted-foreground">
        Toca el botón de un platillo para marcar si hay o se acabó. La página y el WhatsApp se enteran solos.
      </p>

      {secciones.map((g) => (
        <section key={g.id} className="flex flex-col gap-2.5">
          <div className="flex items-baseline justify-between gap-2 px-1">
            <h2 className="text-2xl font-extrabold">{g.nombre}</h2>
            <span className="text-base font-bold text-muted-foreground">
              {g.tipo === "uno" ? "Escoge 1" : g.tipo === "opcional" ? "Opcional" : "Se cobra aparte"}
            </span>
          </div>
          <div className="overflow-hidden rounded-3xl border-2 border-border bg-card">
            {g.items.length === 0 && (
              <p className="p-4 text-base text-muted-foreground">Todavía no hay nada aquí.</p>
            )}
            {g.items.map((it) => {
              const hay = hayHoy(it, hoy);
              const soloHoy = it.disponible && !hay;
              return (
                <div key={it.id} className="flex items-center gap-3 border-t-2 border-border/60 p-3 first:border-t-0">
                  <button
                    type="button"
                    onClick={() => setEdicion({ tipo: "item", item: it })}
                    className="flex min-h-14 min-w-0 flex-1 items-center gap-3 text-left"
                  >
                    <Miniatura it={it} />
                    <span className="flex min-w-0 flex-col">
                      <span className={cn("text-xl font-extrabold leading-tight", !hay && "text-muted-foreground")}>
                        {it.nombre}
                      </span>
                      <span className="text-[15px] font-semibold text-muted-foreground">
                        {soloHoy
                          ? "Se acabó hoy · mañana vuelve"
                          : g.tipo === "extra" && it.precio != null
                            ? `$${Number(it.precio)} · ${resumenDias(it.dias).toLowerCase()}`
                            : resumenDias(it.dias)}
                      </span>
                    </span>
                  </button>
                  {hay ? (
                    <button
                      type="button"
                      onClick={() => setAgotar(it)}
                      aria-label={`${it.nombre}: hay. Tocar si se acabó`}
                      className="flex h-13 w-28 shrink-0 items-center justify-center gap-1.5 rounded-full bg-ok text-lg font-extrabold text-ok-foreground active:scale-95"
                    >
                      <Check className="h-5 w-5" strokeWidth={3} aria-hidden />
                      Hay
                    </button>
                  ) : (
                    <button
                      type="button"
                      onClick={() =>
                        guardarItem(it.id, { disponible: true, agotado_hasta: null }, `${it.nombre}: ya hay otra vez`)
                      }
                      aria-label={`${it.nombre}: agotado. Tocar si ya hay`}
                      className="flex h-13 w-28 shrink-0 items-center justify-center rounded-full border-2 border-primary bg-primary-soft text-lg font-extrabold text-primary active:scale-95"
                    >
                      Agotado
                    </button>
                  )}
                </div>
              );
            })}
          </div>
          {g.id !== "__otros" && (
            <button
              type="button"
              onClick={() => setEdicion({ tipo: "nuevo", grupo: g.id })}
              className="flex min-h-12 items-center gap-2 self-start rounded-full px-3 text-base font-bold text-primary"
            >
              <Plus className="h-5 w-5" strokeWidth={3} aria-hidden />
              Agregar a {g.nombre.toLowerCase()}
            </button>
          )}
        </section>
      ))}

      <HojaUnidad
        abierta={hojaUnidad}
        onCerrar={() => setHojaUnidad(false)}
        config={config}
        uno={uno}
        varios={varios}
        onGuardado={(c) => setConfig(c)}
      />
      <HojaAgotado
        item={agotar}
        onCerrar={() => setAgotar(null)}
        onSoloHoy={async (it) => {
          setAgotar(null);
          await guardarItem(it.id, { agotado_hasta: hoy }, `${it.nombre}: se acabó por hoy`);
        }}
        onHastaQueDiga={async (it) => {
          setAgotar(null);
          await guardarItem(it.id, { disponible: false, agotado_hasta: null }, `${it.nombre}: apagado`);
        }}
      />
      <HojaPlatillo
        edicion={edicion}
        grupos={grupos}
        accountId={accountId}
        items={items}
        onCerrar={() => setEdicion(null)}
        onCambio={(xs) => setItems(xs)}
      />
    </div>
  );
}

// ---------- precio, anticipo y cupo ----------

function HojaUnidad({
  abierta,
  onCerrar,
  config,
  uno,
  varios,
  onGuardado,
}: {
  abierta: boolean;
  onCerrar: () => void;
  config: Config;
  uno: string;
  varios: string;
  onGuardado: (c: Config) => void;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [v, setV] = useState(config);
  const [guardando, setGuardando] = useState(false);
  // Cada vez que se abre, parte de lo guardado.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (abierta) setV(config);
  }, [abierta, config]);

  const paso = (k: "precio_charola" | "anticipo" | "cupo_diario", d: number, min: number) =>
    setV((x) => ({ ...x, [k]: Math.max(min, Number(x[k]) + d) }));

  async function guardar() {
    if (v.dias_entrega.length === 0) return toast.error("Escoge al menos un día de entrega");
    setGuardando(true);
    const cambio = {
      precio_charola: v.precio_charola,
      anticipo: v.anticipo,
      cupo_diario: v.cupo_diario,
      dias_entrega: [...v.dias_entrega].sort(),
      updated_at: new Date().toISOString(),
    };
    const { error } = await supabase.from("menu_config").update(cambio).eq("account_id", config.account_id);
    setGuardando(false);
    if (error) return toast.error("No se pudo guardar. Intenta otra vez.");
    onGuardado({ ...v, dias_entrega: cambio.dias_entrega });
    toast.success("Guardado");
    onCerrar();
  }

  return (
    <Hoja abierta={abierta} onCerrar={onCerrar} titulo={capital(uno)} descripcion="Usa los botones de menos y más.">
      <Pasos
        titulo="Precio"
        ayuda="Sube o baja de 10 en 10"
        texto={`$${Number(v.precio_charola)}`}
        onMenos={() => paso("precio_charola", -10, 10)}
        onMas={() => paso("precio_charola", 10, 10)}
      />
      <Pasos
        titulo="Anticipo"
        ayuda="Lo que pagan para apartar. En $0 no se pide."
        texto={`$${Number(v.anticipo)}`}
        onMenos={() => paso("anticipo", -5, 0)}
        onMas={() => paso("anticipo", 5, 0)}
      />
      <Pasos
        titulo={`${capital(varios)} al día`}
        ayuda="Cuando se llena, la página ya no deja pedir ese día"
        texto={String(v.cupo_diario)}
        onMenos={() => paso("cupo_diario", -1, 1)}
        onMas={() => paso("cupo_diario", 1, 1)}
      />
      <section className="flex flex-col gap-3 rounded-2xl border-2 border-border bg-card p-4">
        <div>
          <h3 className="text-lg font-extrabold">Días que entregas</h3>
          <p className="text-[15px] text-muted-foreground">{resumenDias(v.dias_entrega)}</p>
        </div>
        <ElegirDias dias={v.dias_entrega} onCambio={(d) => setV((x) => ({ ...x, dias_entrega: d }))} />
      </section>
      <BotonGrande onClick={guardar} disabled={guardando}>
        {guardando ? <Loader2 className="h-5 w-5 animate-spin" /> : <Check className="h-6 w-6" strokeWidth={3} />}
        Guardar
      </BotonGrande>
    </Hoja>
  );
}

// ---------- ¿hasta cuándo no hay? ----------

function HojaAgotado({
  item,
  onCerrar,
  onSoloHoy,
  onHastaQueDiga,
}: {
  item: Item | null;
  onCerrar: () => void;
  onSoloHoy: (it: Item) => void;
  onHastaQueDiga: (it: Item) => void;
}) {
  return (
    <Hoja abierta={!!item} onCerrar={onCerrar} titulo={item ? `Se acabó: ${item.nombre}` : ""}>
      {item && (
        <>
          <p className="text-lg font-semibold">¿Hasta cuándo no va a haber?</p>
          <button
            type="button"
            onClick={() => onSoloHoy(item)}
            className="flex min-h-20 flex-col items-start justify-center gap-0.5 rounded-2xl bg-primary px-5 py-3 text-left text-primary-foreground active:scale-[0.98]"
          >
            <span className="text-xl font-extrabold">Solo hoy</span>
            <span className="text-base font-semibold">Mañana vuelve a aparecer solo</span>
          </button>
          <button
            type="button"
            onClick={() => onHastaQueDiga(item)}
            className="flex min-h-20 flex-col items-start justify-center gap-0.5 rounded-2xl border-2 border-input bg-card px-5 py-3 text-left active:scale-[0.98]"
          >
            <span className="text-xl font-extrabold">Hasta que yo diga</span>
            <span className="text-base font-semibold text-muted-foreground">
              Queda apagado hasta que lo vuelvas a prender
            </span>
          </button>
          <div className="flex gap-3 rounded-2xl bg-pendiente-soft p-4 text-pendiente">
            <Info className="mt-0.5 h-5 w-5 shrink-0" aria-hidden />
            <p className="text-base font-semibold leading-snug">
              Los clientes ya no lo verán en la página ni en el WhatsApp. Lo que ya pidieron no cambia.
            </p>
          </div>
          <BotonGrande variante="texto" onClick={onCerrar}>
            No, sí hay
          </BotonGrande>
        </>
      )}
    </Hoja>
  );
}

// ---------- agregar o cambiar un platillo ----------

function HojaPlatillo({
  edicion,
  grupos,
  accountId,
  items,
  onCerrar,
  onCambio,
}: {
  edicion: Edicion | null;
  grupos: GrupoPedido[];
  accountId: string;
  items: Item[];
  onCerrar: () => void;
  onCambio: (xs: Item[]) => void;
}) {
  const supabase = useMemo(() => createClient(), []);
  const actual = edicion?.tipo === "item" ? edicion.item : null;
  const [nombre, setNombre] = useState("");
  const [grupo, setGrupo] = useState("");
  const [dias, setDias] = useState<number[]>(TODOS);
  const [precio, setPrecio] = useState("");
  const [foto, setFoto] = useState("");
  const [guardando, setGuardando] = useState(false);
  const [borrar, setBorrar] = useState(false);

  useEffect(() => {
    if (!edicion) return;
    // Al abrir, el formulario parte del platillo (o vacío si es nuevo).
    /* eslint-disable react-hooks/set-state-in-effect */
    setNombre(actual?.nombre ?? "");
    setGrupo(actual?.grupo ?? (edicion.tipo === "nuevo" ? edicion.grupo : grupos[0]?.id ?? ""));
    setDias(actual?.dias ?? TODOS);
    setPrecio(actual?.precio != null ? String(Number(actual.precio)) : "");
    setFoto(actual?.foto_url ?? "");
    setBorrar(false);
    /* eslint-enable react-hooks/set-state-in-effect */
  }, [edicion, actual, grupos]);

  const esExtra = grupos.find((g) => g.id === grupo)?.tipo === "extra";

  async function guardar() {
    const n = nombre.trim();
    if (!n) return toast.error("Escribe el nombre del platillo");
    if (dias.length === 0) return toast.error("Escoge al menos un día. Si ya no lo haces, mejor quítalo.");
    const p = esExtra ? Number(precio) : null;
    if (esExtra && (!Number.isFinite(p) || precio.trim() === "")) return toast.error("Escribe el precio del extra");
    const datos = {
      nombre: n,
      grupo,
      dias: dias.length === 7 ? null : [...dias].sort(),
      precio: p,
      foto_url: foto.trim() || null,
      updated_at: new Date().toISOString(),
    };
    setGuardando(true);
    let res;
    if (actual) {
      res = await supabase.from("menu_items").update(datos).eq("id", actual.id).select().single();
    } else {
      const orden = Math.max(-1, ...items.filter((x) => x.grupo === grupo).map((x) => x.orden)) + 1;
      res = await supabase
        .from("menu_items")
        .insert({ ...datos, account_id: accountId, orden })
        .select()
        .single();
    }
    setGuardando(false);
    if (res.error) {
      return toast.error(res.error.code === "23505" ? "Ese platillo ya está en el menú" : "No se pudo guardar");
    }
    const fila = res.data as Item;
    onCambio(actual ? items.map((x) => (x.id === fila.id ? fila : x)) : [...items, fila]);
    toast.success(actual ? "Guardado" : `Agregado: ${n}`);
    onCerrar();
  }

  async function quitar() {
    if (!actual) return;
    setGuardando(true);
    const { error } = await supabase.from("menu_items").delete().eq("id", actual.id);
    setGuardando(false);
    if (error) return toast.error("No se pudo quitar");
    onCambio(items.filter((x) => x.id !== actual.id));
    toast.success(`Quitado del menú: ${actual.nombre}`);
    onCerrar();
  }

  return (
    <Hoja abierta={!!edicion} onCerrar={onCerrar} titulo={actual ? actual.nombre : "Agregar platillo"}>
      <form
        className="flex flex-col gap-5"
        onSubmit={(e) => {
          e.preventDefault();
          guardar();
        }}
      >
        <div className="flex items-center gap-3">
          <Miniatura it={{ nombre: nombre || "?", foto_url: foto.trim() || null }} grande />
          <label className="flex min-w-0 flex-1 flex-col gap-1">
            <span className="text-sm font-bold text-muted-foreground">Foto (dirección de la imagen, opcional)</span>
            <input
              value={foto}
              onChange={(e) => setFoto(e.target.value)}
              inputMode="url"
              placeholder="https://…"
              className="h-12 rounded-xl border-2 border-input bg-card px-3 text-base outline-none focus:border-primary"
            />
          </label>
        </div>

        <label className="flex flex-col gap-2">
          <span className="text-lg font-extrabold">Nombre del platillo</span>
          <input
            value={nombre}
            onChange={(e) => setNombre(e.target.value)}
            autoFocus={!actual}
            className="h-14 rounded-2xl border-2 border-input bg-card px-4 text-xl font-bold outline-none focus:border-primary"
          />
        </label>

        <fieldset className="flex flex-col gap-2">
          <legend className="mb-2 text-lg font-extrabold">¿En qué parte va?</legend>
          <div className="grid grid-cols-2 gap-2">
            {grupos.map((g) => (
              <button
                key={g.id}
                type="button"
                aria-pressed={grupo === g.id}
                onClick={() => setGrupo(g.id)}
                className={cn(
                  "flex min-h-14 items-center justify-center gap-1.5 rounded-2xl border-2 px-2 text-lg font-extrabold",
                  grupo === g.id ? "border-primary bg-primary text-primary-foreground" : "border-input bg-card",
                )}
              >
                {grupo === g.id && <Check className="h-5 w-5" strokeWidth={3} aria-hidden />}
                {g.nombre}
              </button>
            ))}
          </div>
        </fieldset>

        {esExtra && (
          <label className="flex flex-col gap-2">
            <span className="text-lg font-extrabold">Precio del extra</span>
            <span className="flex h-14 items-center gap-2 rounded-2xl border-2 border-input bg-card px-4 focus-within:border-primary">
              <span className="text-xl font-bold text-muted-foreground">$</span>
              <input
                value={precio}
                onChange={(e) => setPrecio(e.target.value.replace(/[^\d.]/g, ""))}
                inputMode="decimal"
                className="w-full bg-transparent text-xl font-bold outline-none"
              />
            </span>
          </label>
        )}

        <div className="flex flex-col gap-2">
          <div className="flex items-baseline justify-between">
            <span className="text-lg font-extrabold">¿Qué días lo haces?</span>
            <button type="button" onClick={() => setDias(TODOS)} className="min-h-11 px-2 text-base font-bold text-primary underline">
              Todos
            </button>
          </div>
          <ElegirDias dias={dias} onCambio={setDias} />
          <p className="text-base text-muted-foreground">{resumenDias(dias)}</p>
        </div>

        <BotonGrande type="submit" disabled={guardando}>
          {guardando ? <Loader2 className="h-5 w-5 animate-spin" /> : <Check className="h-6 w-6" strokeWidth={3} />}
          Guardar
        </BotonGrande>

        {actual &&
          (borrar ? (
            <div className="flex flex-col gap-2 rounded-2xl border-2 border-destructive/40 p-4">
              <p className="text-base font-bold">¿Quitar «{actual.nombre}» del menú? Ya no saldrá en ningún lado.</p>
              <div className="grid grid-cols-2 gap-2">
                <BotonGrande variante="borde" onClick={() => setBorrar(false)}>
                  No
                </BotonGrande>
                <BotonGrande className="bg-destructive text-white" onClick={quitar} disabled={guardando}>
                  Sí, quitar
                </BotonGrande>
              </div>
            </div>
          ) : (
            <button
              type="button"
              onClick={() => setBorrar(true)}
              className="flex min-h-12 items-center justify-center gap-2 self-center text-base font-bold text-destructive"
            >
              <Trash2 className="h-5 w-5" aria-hidden />
              Quitar del menú
            </button>
          ))}
      </form>
    </Hoja>
  );
}
