"use client";

// ============================================================
// «Tu negocio» — todo lo que cambia de un negocio a otro, sin tocar código:
//   CRM        → negocio_config (menú, logo, botones y alertas por columna,
//                resumen de la tarjeta, avisos, textos)
//   Agente     → bot_config (quién es, cómo habla, qué ofrece, ejemplos)
//   Entrevista → bot_entrevista (preguntas para conocer al cliente)
// Solo el dueño o un admin guarda (las políticas de la base lo exigen).
// ============================================================

import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { ArrowDown, ArrowUp, Loader2, Plus, Trash2 } from "lucide-react";

import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { useNegocio } from "@/hooks/use-negocio";
import { SECCIONES, leerNegocio, normalizar, type NegocioConfig, type Seccion } from "@/lib/negocio/config";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { SettingsPanelHead } from "./settings-panel-head";

type Obj = Record<string, unknown>;

const NOMBRE_SECCION: Record<Seccion, string> = {
  pipelines: "Tablero",
  inbox: "Mensajes",
  catalogo: "Catálogo / Paquetes",
  cocinar: "Qué cocinar",
  menu: "Menú de comida",
  contacts: "Clientes",
};

const lista = (s: string) =>
  s
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);

const texto = (x: unknown) => (typeof x === "string" ? x : "");

// ---------- piezas pequeñas ----------

function Campo({
  label,
  ayuda,
  children,
}: {
  label: string;
  ayuda?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-1.5">
      <Label>{label}</Label>
      {children}
      {ayuda ? <p className="text-xs text-muted-foreground">{ayuda}</p> : null}
    </div>
  );
}

function BotonGuardar({ onClick, guardando, disabled }: { onClick: () => void; guardando: boolean; disabled?: boolean }) {
  return (
    <Button onClick={onClick} disabled={guardando || disabled}>
      {guardando ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : null}
      Guardar
    </Button>
  );
}

/** Editor de JSON completo para lo que no tiene formulario. */
function EditorJson({ valor, onCambio }: { valor: Obj; onCambio: (v: Obj) => void }) {
  const [txt, setTxt] = useState(() => JSON.stringify(valor, null, 2));
  const [error, setError] = useState("");
  return (
    <div className="space-y-2">
      <Textarea
        value={txt}
        onChange={(e) => {
          setTxt(e.target.value);
          try {
            const v = JSON.parse(e.target.value);
            if (typeof v !== "object" || v === null || Array.isArray(v)) throw new Error("Debe ser un objeto { }");
            setError("");
            onCambio(v);
          } catch (err) {
            setError(err instanceof Error ? err.message : "JSON inválido");
          }
        }}
        rows={22}
        className="font-mono text-xs"
        spellCheck={false}
      />
      {error ? <p className="text-xs text-destructive">No se guarda hasta corregirlo: {error}</p> : null}
    </div>
  );
}

// ---------- carga y guardado genérico de una fila jsonb por cuenta ----------

function useFila(tabla: "negocio_config" | "bot_config" | "bot_entrevista", accountId: string | null) {
  const [data, setData] = useState<Obj | null>(null);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);

  useEffect(() => {
    if (!accountId) return;
    let vivo = true;
    createClient()
      .from(tabla)
      .select("data")
      .eq("account_id", accountId)
      .maybeSingle()
      .then(({ data: fila, error }) => {
        if (!vivo) return;
        if (error) toast.error("No se pudo leer la configuración");
        setData((fila?.data as Obj) ?? {});
        setCargando(false);
      });
    return () => {
      vivo = false;
    };
  }, [tabla, accountId]);

  const guardar = useCallback(
    async (nuevo: Obj) => {
      if (!accountId) return false;
      setGuardando(true);
      const { error } = await createClient()
        .from(tabla)
        .upsert({ account_id: accountId, data: nuevo, updated_at: new Date().toISOString() }, { onConflict: "account_id" });
      setGuardando(false);
      if (error) {
        toast.error(error.code === "42501" ? "Solo el dueño o un admin puede cambiar esto" : "No se pudo guardar");
        return false;
      }
      setData(nuevo);
      toast.success("Guardado");
      return true;
    },
    [tabla, accountId],
  );

  return { data, setData, cargando, guardando, guardar };
}

// ============================================================
// CRM
// ============================================================

function PestanaCrm({ accountId, puede }: { accountId: string; puede: boolean }) {
  const fila = useFila("negocio_config", accountId);
  const { recargar } = useNegocio();
  const [columnas, setColumnas] = useState<string[]>([]);
  const [json, setJson] = useState(false);

  useEffect(() => {
    let vivo = true;
    createClient()
      .from("pipeline_stages")
      .select("name, position, pipeline:pipelines!inner(account_id)")
      .eq("pipeline.account_id", accountId)
      .order("position")
      .then(({ data }) => {
        if (!vivo) return;
        setColumnas([...new Set((data ?? []).map((s) => s.name as string))]);
      });
    return () => {
      vivo = false;
    };
  }, [accountId]);

  const raw = fila.data;
  const cfg: NegocioConfig = useMemo(() => leerNegocio(raw), [raw]);
  if (fila.cargando || !raw) return <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />;

  const set = (cambio: Obj) => fila.setData({ ...raw, ...cambio });
  const rawColumnas = (raw.columnas as Obj) ?? {};
  // Busca la llave que ya existe para esa columna (sin importar acentos) o usa el nombre.
  const llaveColumna = (nombre: string) =>
    Object.keys(rawColumnas).find((k) => normalizar(k) === normalizar(nombre)) ?? nombre;
  const setColumna = (nombre: string, cambio: Obj) => {
    const k = llaveColumna(nombre);
    const actual = (rawColumnas[k] as Obj) ?? {};
    set({ columnas: { ...rawColumnas, [k]: { ...actual, ...cambio } } });
  };
  const avisos = (raw.avisos as Obj) ?? {};
  const nuevo = (avisos.nuevo as Obj) ?? {};
  const seg = (avisos.seguimiento as Obj | null) ?? null;
  const tarjeta = (raw.tarjeta as Obj) ?? {};

  const guardar = async () => {
    if (await fila.guardar(raw)) recargar();
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-3">
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          <Checkbox checked={json} onCheckedChange={(v) => setJson(v === true)} /> Editar como JSON (avanzado)
        </label>
        <BotonGuardar onClick={guardar} guardando={fila.guardando} disabled={!puede} />
      </div>

      {json ? (
        <EditorJson valor={raw} onCambio={(v) => fila.setData(v)} />
      ) : (
        <>
          <Card>
            <CardHeader>
              <CardTitle>Marca y menú</CardTitle>
              <CardDescription>Cómo se ve el CRM para este negocio.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="grid gap-4 sm:grid-cols-2">
                <Campo label="Nombre del negocio">
                  <Input value={texto(raw.nombre)} onChange={(e) => set({ nombre: e.target.value })} />
                </Campo>
                <Campo label="Logo (dirección de la imagen)" ayuda="Ej. /logo-onlinefreedom.svg o https://…/logo.png">
                  <Input
                    value={texto((raw.logo as Obj)?.src)}
                    onChange={(e) => set({ logo: { ...cfg.logo, ...((raw.logo as Obj) ?? {}), src: e.target.value } })}
                  />
                </Campo>
              </div>
              <Campo label="Secciones del menú" ayuda="Las que no marques siguen existiendo, pero no salen en el menú.">
                <div className="flex flex-wrap gap-x-5 gap-y-2 pt-1">
                  {SECCIONES.map((s) => (
                    <label key={s} className="flex items-center gap-2 text-sm">
                      <Checkbox
                        checked={cfg.menu.includes(s)}
                        onCheckedChange={(v) =>
                          set({
                            menu: SECCIONES.filter((x) => (x === s ? v === true : cfg.menu.includes(x))),
                          })
                        }
                      />
                      {NOMBRE_SECCION[s]}
                    </label>
                  ))}
                </div>
              </Campo>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Columnas del tablero</CardTitle>
              <CardDescription>
                El botón de un toque que pasa una tarjeta a cada columna, y cuántos días puede estar ahí antes de
                marcarla en rojo.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              {columnas.length === 0 ? <p className="text-sm text-muted-foreground">Todavía no hay columnas.</p> : null}
              {columnas.map((c) => {
                const col = (rawColumnas[llaveColumna(c)] as Obj) ?? {};
                return (
                  <div key={c} className="grid items-end gap-3 sm:grid-cols-[1fr_1.4fr_9rem]">
                    <p className="pb-2 text-sm font-medium">{c}</p>
                    <Campo label="Botón para pasar aquí">
                      <Input
                        value={texto(col.boton)}
                        placeholder={`Pasar a ${c}`}
                        onChange={(e) => setColumna(c, { boton: e.target.value })}
                      />
                    </Campo>
                    <Campo label="Rojo a los (días)">
                      <Input
                        type="number"
                        min={0}
                        value={typeof col.alerta_dias === "number" ? String(col.alerta_dias) : ""}
                        placeholder="Nunca"
                        onChange={(e) =>
                          setColumna(c, { alerta_dias: e.target.value === "" ? null : Math.max(0, Number(e.target.value)) })
                        }
                      />
                    </Campo>
                  </div>
                );
              })}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Tarjeta y avisos</CardTitle>
              <CardDescription>
                Qué datos de la ficha se ven en la tarjeta y en el aviso al celular. Se escriben como en la ficha
                («Giro», «Reto», «Llamada»), separados por coma.
              </CardDescription>
            </CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              <Campo label="Resumen en la tarjeta">
                <Input
                  value={cfg.tarjeta.resumen.join(", ")}
                  onChange={(e) => set({ tarjeta: { ...tarjeta, resumen: lista(e.target.value) } })}
                />
              </Campo>
              <Campo label="Resaltados en azul">
                <Input
                  value={cfg.tarjeta.destacar.map((d) => d.clave).join(", ")}
                  onChange={(e) =>
                    set({ tarjeta: { ...tarjeta, destacar: lista(e.target.value).map((k) => ({ clave: k, etiqueta: k })) } })
                  }
                />
              </Campo>
              <Campo label="Título del aviso de tarjeta nueva">
                <Input
                  value={texto(nuevo.titulo)}
                  placeholder="Nueva tarjeta"
                  onChange={(e) => set({ avisos: { ...avisos, nuevo: { ...nuevo, titulo: e.target.value } } })}
                />
              </Campo>
              <Campo label="Datos en el aviso">
                <Input
                  value={cfg.avisos.nuevo.resumen.join(", ")}
                  onChange={(e) => set({ avisos: { ...avisos, nuevo: { ...nuevo, resumen: lista(e.target.value) } } })}
                />
              </Campo>
              <Campo label="Aviso de seguimiento: columna" ayuda="Cada mañana avisa de las tarjetas que llevan días ahí.">
                <select
                  className="h-9 w-full rounded-md border border-input bg-transparent px-3 text-sm"
                  value={texto(seg?.columna)}
                  onChange={(e) =>
                    set({
                      avisos: {
                        ...avisos,
                        seguimiento: e.target.value
                          ? { dias: 3, singular: "tarjeta", plural: "tarjetas", ...(seg ?? {}), columna: e.target.value }
                          : null,
                      },
                    })
                  }
                >
                  <option value="">Sin aviso de seguimiento</option>
                  {columnas.map((c) => (
                    <option key={c} value={c}>
                      {c}
                    </option>
                  ))}
                </select>
              </Campo>
              {seg ? (
                <div className="grid grid-cols-3 gap-2">
                  <Campo label="Días">
                    <Input
                      type="number"
                      min={1}
                      value={String(seg.dias ?? 3)}
                      onChange={(e) =>
                        set({ avisos: { ...avisos, seguimiento: { ...seg, dias: Math.max(1, Number(e.target.value) || 1) } } })
                      }
                    />
                  </Campo>
                  <Campo label="Una">
                    <Input
                      value={texto(seg.singular)}
                      onChange={(e) => set({ avisos: { ...avisos, seguimiento: { ...seg, singular: e.target.value } } })}
                    />
                  </Campo>
                  <Campo label="Varias">
                    <Input
                      value={texto(seg.plural)}
                      onChange={(e) => set({ avisos: { ...avisos, seguimiento: { ...seg, plural: e.target.value } } })}
                    />
                  </Campo>
                </div>
              ) : null}
            </CardContent>
          </Card>
          <p className="text-xs text-muted-foreground">
            Los textos de la app («Ventas», «Nuevo prospecto»…) se cambian en «Editar como JSON», en «textos».
          </p>
        </>
      )}
    </div>
  );
}

// ============================================================
// Agente
// ============================================================

const CAMPOS_AGENTE: { k: string; label: string; ayuda?: string; filas?: number }[] = [
  { k: "negocio", label: "Nombre del negocio (como lo dice el agente)" },
  { k: "rol", label: "Quién es el agente", filas: 3 },
  { k: "voz", label: "Cómo escribe", ayuda: "Ej. un asesor de Saltillo, amable y directo", filas: 2 },
  { k: "quien_atiende", label: "Quién atiende cuando pasa el chat a una persona", ayuda: "Ej. Julio" },
  { k: "objetivo", label: "Meta de la plática", filas: 3 },
  { k: "contexto", label: "Lo que debe saber del negocio", filas: 8 },
  { k: "catalogo_nota", label: "Nota sobre precios y catálogo", filas: 3 },
  { k: "fuera_de_catalogo", label: "Qué dice si piden algo que no está en el catálogo", filas: 2 },
  { k: "ejemplos", label: "Ejemplos de respuestas", filas: 12 },
];

function PestanaAgente({ accountId, puede }: { accountId: string; puede: boolean }) {
  const fila = useFila("bot_config", accountId);
  const [json, setJson] = useState(false);
  const raw = fila.data;
  if (fila.cargando || !raw) return <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />;
  const set = (cambio: Obj) => fila.setData({ ...raw, ...cambio });
  const pasos = Array.isArray(raw.pasos) ? (raw.pasos as unknown[]).map(texto) : [];

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-3">
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          <Checkbox checked={json} onCheckedChange={(v) => setJson(v === true)} /> Editar como JSON (avanzado)
        </label>
        <BotonGuardar onClick={() => fila.guardar(raw)} guardando={fila.guardando} disabled={!puede} />
      </div>
      <p className="text-xs text-muted-foreground">
        El agente usa esto desde su siguiente mensaje. Para cambios grandes al prompt, pásalos primero por la
        revisión de prompts.
      </p>
      {json ? (
        <EditorJson valor={raw} onCambio={(v) => fila.setData(v)} />
      ) : (
        <Card>
          <CardContent className="space-y-4 pt-6">
            <Campo label="Trato">
              <select
                className="h-9 w-full rounded-md border border-input bg-transparent px-3 text-sm sm:w-48"
                value={texto(raw.trato) || "tú"}
                onChange={(e) => set({ trato: e.target.value })}
              >
                <option value="usted">De usted</option>
                <option value="tú">De tú</option>
              </select>
            </Campo>
            {CAMPOS_AGENTE.map((c) => (
              <Campo key={c.k} label={c.label} ayuda={c.ayuda}>
                {c.filas ? (
                  <Textarea rows={c.filas} value={texto(raw[c.k])} onChange={(e) => set({ [c.k]: e.target.value })} />
                ) : (
                  <Input value={texto(raw[c.k])} onChange={(e) => set({ [c.k]: e.target.value })} />
                )}
              </Campo>
            ))}
            <Campo label="Pasos de la plática" ayuda="Uno por renglón, en orden.">
              <Textarea
                rows={5}
                value={pasos.join("\n")}
                onChange={(e) => set({ pasos: e.target.value.split("\n").filter((l) => l.trim() !== "") })}
              />
            </Campo>
            <p className="text-xs text-muted-foreground">
              Datos que pide, horario, herramientas y lo demás: en «Editar como JSON».
            </p>
          </CardContent>
        </Card>
      )}
    </div>
  );
}

// ============================================================
// Entrevista
// ============================================================

function PestanaEntrevista({ accountId, puede }: { accountId: string; puede: boolean }) {
  const fila = useFila("bot_entrevista", accountId);
  const [json, setJson] = useState(false);
  const raw = fila.data;
  if (fila.cargando || !raw) return <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />;

  const preguntas = Array.isArray(raw.preguntas) ? (raw.preguntas as Obj[]) : [];
  const setPreguntas = (p: Obj[]) => fila.setData({ ...raw, preguntas: p });
  const setP = (i: number, cambio: Obj) => setPreguntas(preguntas.map((p, j) => (j === i ? { ...p, ...cambio } : p)));
  const mover = (i: number, d: number) => {
    const j = i + d;
    if (j < 0 || j >= preguntas.length) return;
    const p = [...preguntas];
    [p[i], p[j]] = [p[j], p[i]];
    setPreguntas(p);
  };
  const agregar = () => {
    let n = preguntas.length + 1;
    while (preguntas.some((p) => p.clave === `p${n}`)) n++;
    setPreguntas([...preguntas, { clave: `p${n}`, etiqueta: "", pregunta: "", ayuda: "" }]);
  };
  const guardar = () => {
    const vacia = preguntas.findIndex((p) => !texto(p.etiqueta).trim() || !texto(p.pregunta).trim());
    if (vacia >= 0) {
      toast.error(`A la pregunta ${vacia + 1} le falta el tema o la pregunta`);
      return;
    }
    fila.guardar(raw);
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-3">
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          <Checkbox checked={json} onCheckedChange={(v) => setJson(v === true)} /> Editar como JSON (avanzado)
        </label>
        <BotonGuardar onClick={guardar} guardando={fila.guardando} disabled={!puede} />
      </div>
      <p className="text-xs text-muted-foreground">
        Las preguntas que hace el agente cuando el cliente elige contestarlas por el chat, en este orden. El
        «tema» es la línea donde queda la respuesta en la ficha. Si cambias preguntas, actualiza también el PDF.
      </p>
      {json ? (
        <EditorJson valor={raw} onCambio={(v) => fila.setData(v)} />
      ) : (
        <>
          {preguntas.map((p, i) => (
            <Card key={texto(p.clave) || i}>
              <CardContent className="space-y-3 pt-5">
                <div className="flex items-center justify-between gap-2">
                  <p className="text-sm font-semibold">
                    {i + 1}.{" "}
                    {Array.isArray(p.si) && p.si.length ? (
                      <span className="font-normal text-muted-foreground">(solo si se cumple una condición)</span>
                    ) : null}
                  </p>
                  <div className="flex gap-1">
                    <Button variant="ghost" size="icon" aria-label="Subir" onClick={() => mover(i, -1)}>
                      <ArrowUp className="h-4 w-4" />
                    </Button>
                    <Button variant="ghost" size="icon" aria-label="Bajar" onClick={() => mover(i, 1)}>
                      <ArrowDown className="h-4 w-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label="Quitar"
                      onClick={() => setPreguntas(preguntas.filter((_, j) => j !== i))}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </div>
                </div>
                <div className="grid gap-3 sm:grid-cols-[14rem_1fr]">
                  <Campo label="Tema">
                    <Input value={texto(p.etiqueta)} onChange={(e) => setP(i, { etiqueta: e.target.value })} />
                  </Campo>
                  <Campo label="Pregunta">
                    <Input value={texto(p.pregunta)} onChange={(e) => setP(i, { pregunta: e.target.value })} />
                  </Campo>
                </div>
                <Campo label="Ayuda (si no la entiende)">
                  <Textarea rows={2} value={texto(p.ayuda)} onChange={(e) => setP(i, { ayuda: e.target.value })} />
                </Campo>
              </CardContent>
            </Card>
          ))}
          <Button variant="outline" onClick={agregar}>
            <Plus className="mr-2 h-4 w-4" /> Agregar pregunta
          </Button>
          <Campo label="Qué hace al terminar">
            <Textarea rows={3} value={texto(raw.cierre)} onChange={(e) => fila.setData({ ...raw, cierre: e.target.value })} />
          </Campo>
        </>
      )}
    </div>
  );
}

// ============================================================

export function NegocioPanel() {
  const { accountId, canEditSettings } = useAuth();
  if (!accountId) return <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />;
  return (
    <div>
      <SettingsPanelHead
        title="Tu negocio"
        description="Lo que hace distinto a este negocio: cómo se ve el CRM, cómo habla el agente y qué pregunta en la entrevista."
      />
      {!canEditSettings ? (
        <p className="mb-4 rounded-md border border-border bg-muted/40 p-3 text-sm text-muted-foreground">
          Solo el dueño o un admin puede guardar cambios aquí.
        </p>
      ) : null}
      <Tabs defaultValue="crm">
        <TabsList>
          <TabsTrigger value="crm">CRM</TabsTrigger>
          <TabsTrigger value="agente">Agente</TabsTrigger>
          <TabsTrigger value="entrevista">Entrevista</TabsTrigger>
        </TabsList>
        <TabsContent value="crm" className="pt-4">
          <PestanaCrm accountId={accountId} puede={canEditSettings} />
        </TabsContent>
        <TabsContent value="agente" className="pt-4">
          <PestanaAgente accountId={accountId} puede={canEditSettings} />
        </TabsContent>
        <TabsContent value="entrevista" className="pt-4">
          <PestanaEntrevista accountId={accountId} puede={canEditSettings} />
        </TabsContent>
      </Tabs>
    </div>
  );
}
