"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { useTranslations } from "next-intl";
import { BarChart3, Check, Copy, Download, Loader2, Search } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusPill } from "@/components/status/status-pill";
import { ServiceDot } from "@/components/service/service-dot";
import { MoneyTotalFigure } from "@/components/money/money-total-figure";
import { moneyStripeElevatedClass } from "@/lib/money-tone";
import { formatNumber } from "@/lib/format-number";
import { historialDestino } from "@/lib/resumen/historial-destino";
import {
  ESTADO_GRUPOS,
  estadoCounts,
  formatOperacionHora,
  historialCsv,
  historialCsvFilename,
  isSingleDay,
  periodoActivo,
  type EstadoCounts,
  type EstadoFiltro,
  type HistorialFila,
} from "@/lib/finanzas/operaciones-historial";
import { cn } from "@/lib/utils";
import { serviceNameEs } from "@/lib/service-name";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

interface ResumenPeriodo {
  orden: number;
  periodo: string;
  desde: string;
  hasta: string;
  operaciones: number;
  volumen_gyd: number;
  ticket_medio_gyd: number;
}

// El RPC devuelve los periodos en orden fijo (1..5): hoy, ayer, esta
// semana, este mes, mes pasado. Traducimos por `orden` en vez de por
// el string, que puede variar.
const PERIODO_ORDEN: Record<
  number,
  "hoy" | "ayer" | "semana" | "mes" | "mes_anterior"
> = {
  1: "hoy",
  2: "ayer",
  3: "semana",
  4: "mes",
  5: "mes_anterior",
};

// Mismos nombres que la Calculadora y el cierre; el valor que viaja al RPC es el del libro (la 229 lo entiende, además de
// los service_type de siempre).
const SERVICIOS = [
  "CUP",
  "ZELLE",
  "CLASICA",
  "TROPICAL",
  "EFECTIVO",
  "RECARGA",
  "SALDO_MOVIL",
  "COMBO",
  "VISA",
  "MIXTA",
  "TRADUCCION",
  "MEXICO",
] as const;

// El RPC acota el limite a 200; el CSV pide lotes de ese tamano hasta este tope.
const LOTE_EXPORTAR = 200;
const TOPE_EXPORTAR = 5000;
const DEBOUNCE_MS = 300;

// El historial se pide por páginas: crece ~16 filas al día y antes se
// pedían 200 de un tiro, así que a finales de agosto la tabla habría
// empezado a cortar en silencio (la 088 lo cuenta entero).
const TAMANOS_PAGINA = [25, 50, 100] as const;

// En castellano y aquí dentro, como el "Retry" de más
// abajo: son cuatro etiquetas y no compensa mover messages/en.json
// entero por ellas.
const PAG_TXT = {
  porPagina: "Por página",
  anterior: "Anterior",
  siguiente: "Siguiente",
  mostrando: (desde: number, hasta: number, total: number) =>
    `Mostrando ${desde}–${hasta} de ${total}`,
};

function fmtGyd(n: number | null | undefined): string {
  return `${formatNumber(n ?? 0)} GYD`;
}

/** Centinela para "todos los servicios": el valor real que viaja al RPC es "". */
const TODOS = "__todos__";

/** Etiqueta encima del control, que es lo que `space-y-1` no hacia. */
function Field({
  label,
  className,
  children,
}: {
  label: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={`flex flex-col gap-1.5 ${className ?? ""}`}>
      <span className="text-xs font-medium text-muted-foreground">{label}</span>
      {children}
    </div>
  );
}

interface Filtros {
  servicio: string;
  desde: string;
  hasta: string;
  estado: EstadoFiltro;
  buscar: string;
}

const FILTROS_INICIALES: Filtros = { servicio: "", desde: "", hasta: "", estado: "all", buscar: "" };

const ESTADO_FILTROS: ReadonlyArray<EstadoFiltro> = ["all", ...ESTADO_GRUPOS];

function rpcParams(f: Filtros) {
  return {
    p_desde: f.desde || null,
    p_hasta: f.hasta || null,
    p_servicio: f.servicio || null,
    p_buscar: f.buscar.trim() || null,
  };
}

/** Period summary and operations history, searched from the Cierres tab. No "Abrir chat": the history is for looking things up. */
export function HistorialBusqueda() {
  const t = useTranslations("Resumen.page");
  const tStatus = useTranslations("Inbox.operationsPanel.status");
  const [resumen, setResumen] = useState<ResumenPeriodo[] | null>(null);
  const [historial, setHistorial] = useState<HistorialFila[] | null>(null);
  const [counts, setCounts] = useState<EstadoCounts | null>(null);
  const [error, setError] = useState<string | null>(null);
  // `missing`: the database has no migration 351 yet (the RPC does not exist).
  const [historialError, setHistorialError] = useState<{ msg: string; missing: boolean } | null>(null);
  const [filtros, setFiltros] = useState<Filtros>(FILTROS_INICIALES);
  const [buscarInput, setBuscarInput] = useState("");
  const [pagina, setPagina] = useState(0);
  const [porPagina, setPorPagina] = useState<number>(TAMANOS_PAGINA[0]);
  const [total, setTotal] = useState(0);
  const [cargando, setCargando] = useState(false);
  const [exportando, setExportando] = useState(false);
  const [exportNota, setExportNota] = useState<string | null>(null);
  const [copiado, setCopiado] = useState<string | null>(null);
  const debounce = useRef<ReturnType<typeof setTimeout> | null>(null);
  const peticion = useRef(0);

  const statusLabel = useCallback((s: string) => (tStatus.has(s) ? tStatus(s) : s), [tStatus]);

  const loadResumen = useCallback(async () => {
    try {
      const supabase = createClient();
      const { data, error: rpcErr } = await supabase.rpc("cerebro_dashboard_resumen");
      if (rpcErr) throw new Error(rpcErr.message);
      setResumen((data ?? []) as ResumenPeriodo[]);
    } catch (err) {
      console.error("[resumen]", err);
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  // Un cambio de filtro vuelve a la primera pagina: quedarse en la 4 con un filtro que devuelve 12 filas dejaria la tabla
  // vacia sin explicacion.
  const cambiar = useCallback((cambio: Partial<Filtros>) => {
    setFiltros((f) => ({ ...f, ...cambio }));
    setPagina(0);
  }, []);

  const loadHistorial = useCallback(
    async (f: Filtros, pag: number, tam: number) => {
      const id = ++peticion.current;
      setCargando(true);
      setHistorialError(null);
      try {
        const supabase = createClient();
        const { data, error: rpcErr } = await supabase.rpc("crm_historial_operaciones", {
          ...rpcParams(f),
          p_estado: f.estado === "all" ? null : f.estado,
          p_limite: tam,
          p_desde_fila: pag * tam,
        });
        if (id !== peticion.current) return;
        if (rpcErr) throw rpcErr;
        const filas = (data ?? []) as HistorialFila[];
        setHistorial(filas);
        // `total` viene repetido en cada fila; sin filas, no hay nada.
        setTotal(filas[0]?.total ?? 0);
      } catch (err) {
        if (id !== peticion.current) return;
        console.error("[resumen] historial:", err);
        setHistorial((h) => h ?? []);
        const e = err as { message?: string; code?: string };
        setHistorialError({
          msg: e.message ?? String(err),
          missing: e.code === "PGRST202" || /crm_historial/.test(e.message ?? ""),
        });
      } finally {
        if (id === peticion.current) setCargando(false);
      }
    },
    [],
  );

  const loadCounts = useCallback(async (f: Filtros) => {
    try {
      const supabase = createClient();
      const { data, error: rpcErr } = await supabase.rpc("crm_historial_estados", rpcParams(f));
      if (rpcErr) throw rpcErr;
      setCounts(estadoCounts((data ?? []) as Array<{ grupo: string; cantidad: number }>));
    } catch (err) {
      console.error("[resumen] estados:", err);
      setCounts(null);
    }
  }, []);

  useEffect(() => {
    void loadResumen();
  }, [loadResumen]);

  useEffect(() => {
    void loadHistorial(filtros, pagina, porPagina);
  }, [loadHistorial, filtros, pagina, porPagina]);

  // Los contadores no dependen del estado elegido ni de la pagina.
  const { desde, hasta, servicio, buscar } = filtros;
  useEffect(() => {
    void loadCounts({ servicio, desde, hasta, buscar, estado: "all" });
  }, [loadCounts, servicio, desde, hasta, buscar]);

  useEffect(
    () => () => {
      if (debounce.current) clearTimeout(debounce.current);
    },
    [],
  );

  const onBuscar = (value: string) => {
    setBuscarInput(value);
    if (debounce.current) clearTimeout(debounce.current);
    debounce.current = setTimeout(() => cambiar({ buscar: value }), DEBOUNCE_MS);
  };

  const elegirPeriodo = (p: ResumenPeriodo) => {
    // Pulsar el periodo activo lo suelta: la tabla vuelve a no tener rango.
    const activo = periodoActivo(resumen ?? [], filtros.desde, filtros.hasta) === p.orden;
    cambiar(activo ? { desde: "", hasta: "" } : { desde: p.desde, hasta: p.hasta });
  };

  const copiarId = async (id: string) => {
    try {
      await navigator.clipboard.writeText(id);
      setCopiado(id);
      setTimeout(() => setCopiado((c) => (c === id ? null : c)), 1500);
    } catch {
      // Sin permiso de portapapeles no hay nada que hacer: el ID sigue en el CSV.
    }
  };

  const exportar = async () => {
    setExportando(true);
    setExportNota(null);
    try {
      const supabase = createClient();
      const todas: HistorialFila[] = [];
      let totalFiltro = 0;
      while (todas.length < TOPE_EXPORTAR) {
        const { data, error: rpcErr } = await supabase.rpc("crm_historial_operaciones", {
          ...rpcParams(filtros),
          p_estado: filtros.estado === "all" ? null : filtros.estado,
          p_limite: LOTE_EXPORTAR,
          p_desde_fila: todas.length,
        });
        if (rpcErr) throw rpcErr;
        const lote = (data ?? []) as HistorialFila[];
        totalFiltro = lote[0]?.total ?? totalFiltro;
        todas.push(...lote);
        if (lote.length < LOTE_EXPORTAR || todas.length >= totalFiltro) break;
      }
      const filas = todas.slice(0, TOPE_EXPORTAR);
      const url = URL.createObjectURL(new Blob([historialCsv(filas, statusLabel)], { type: "text/csv;charset=utf-8" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = historialCsvFilename(filtros.desde, filtros.hasta);
      link.click();
      URL.revokeObjectURL(url);
      if (totalFiltro > TOPE_EXPORTAR) setExportNota(t("exportarTope", { max: formatNumber(TOPE_EXPORTAR), total: formatNumber(totalFiltro) }));
    } catch (err) {
      console.error("[resumen] exportar:", err);
      setExportNota(t("exportarError"));
    } finally {
      setExportando(false);
    }
  };

  const primeraFila = total === 0 ? 0 : pagina * porPagina + 1;
  const ultimaFila = Math.min((pagina + 1) * porPagina, total);
  const haySiguiente = (pagina + 1) * porPagina < total;
  const unDia = isSingleDay(filtros.desde, filtros.hasta);
  const periodoOrden = periodoActivo(resumen ?? [], filtros.desde, filtros.hasta);

  if (error) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-2">
        <p className="text-sm text-destructive">{t("error", { msg: error })}</p>
        <Button variant="outline" onClick={() => window.location.reload()}>
          {t("retry")}
        </Button>
      </div>
    );
  }

  if (resumen === null || historial === null) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="min-w-0 space-y-6">
      {/* Resumen por periodo: cada tarjeta fija el rango de la tabla */}
      <section data-testid="resumen-section" className="space-y-2">
        <h2 className="text-base font-semibold tracking-tight text-foreground">{t("resumenTitle")}</h2>
        <div role="group" aria-label={t("periodoGrupo")} className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
          {resumen.map((p) => {
            const labelKey = PERIODO_ORDEN[p.orden] ?? null;
            const label = labelKey ? t(`periodos.${labelKey}`) : p.periodo;
            const activo = periodoOrden === p.orden;
            return (
              <button
                key={p.orden}
                type="button"
                data-testid="resumen-card"
                aria-pressed={activo}
                onClick={() => elegirPeriodo(p)}
                className={cn(
                  "min-h-11 min-w-0 rounded-xl border bg-card p-4 text-left transition-colors hover:bg-muted/40 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring",
                  moneyStripeElevatedClass.in,
                  activo ? "border-2 border-foreground" : "border-border",
                )}
              >
                <p className="text-xs font-medium text-muted-foreground">{label}</p>
                <p className="mt-2 text-xl font-bold tabular-nums text-foreground">
                  <MoneyTotalFigure kind="in" value={p.volumen_gyd} format={fmtGyd} />
                </p>
                <p className="mt-2 text-sm font-semibold tabular-nums text-foreground">
                  {p.operaciones} <span className="text-xs font-normal text-muted-foreground">{t("operaciones")}</span>
                </p>
                <p className="mt-0.5 text-[11px] tabular-nums text-muted-foreground">
                  {t("ticketMedio")}: {fmtGyd(p.ticket_medio_gyd)}
                </p>
              </button>
            );
          })}
        </div>
        <p className="text-[11px] text-muted-foreground/70">{t("noteDesde")}</p>
      </section>

      {/* Historial */}
      <section data-testid="historial-section" className="min-w-0 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h2 className="text-base font-semibold tracking-tight text-foreground">{t("historialTitle")}</h2>
          <Button type="button" variant="outline" size="sm" onClick={() => void exportar()} disabled={exportando || total === 0}>
            {exportando ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <Download className="mr-1.5 h-3.5 w-3.5" />}
            {exportando ? t("exportando") : t("exportar")}
          </Button>
        </div>
        {exportNota && (
          <p role="status" data-testid="export-note" className="text-xs text-muted-foreground">
            {exportNota}
          </p>
        )}

        <div className="space-y-3 rounded-xl border border-border bg-card tarjeta-elevada p-3">
          <div className="flex flex-wrap items-end gap-3">
            <Field label={t("filtros.buscar")} className="min-w-0 flex-1 basis-60">
              <div className="relative">
                <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  type="search"
                  value={buscarInput}
                  onChange={(e) => onBuscar(e.target.value)}
                  placeholder={t("filtros.buscarPlaceholder")}
                  className="w-full pl-8"
                />
              </div>
            </Field>
            <Field label={t("filtros.servicio")}>
              <Select value={filtros.servicio || TODOS} onValueChange={(v) => cambiar({ servicio: !v || v === TODOS ? "" : v })}>
                <SelectTrigger className="w-40">
                  {/* Base UI pinta el valor en crudo si no le das la etiqueta, asi que el centinela saldria literal. */}
                  <SelectValue>
                    {(v) => (v === TODOS || !v ? t("filtros.todos") : (serviceNameEs(v as string) ?? (v as string)))}
                  </SelectValue>
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={TODOS}>{t("filtros.todos")}</SelectItem>
                  {SERVICIOS.map((s) => (
                    <SelectItem key={s} value={s}>
                      {serviceNameEs(s)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field label={t("filtros.desde")}>
              <Input type="date" value={filtros.desde} onChange={(e) => cambiar({ desde: e.target.value })} className="w-40" />
            </Field>
            <Field label={t("filtros.hasta")}>
              <Input type="date" value={filtros.hasta} onChange={(e) => cambiar({ hasta: e.target.value })} className="w-40" />
            </Field>
          </div>

          <div role="group" aria-label={t("estadoGrupo")} className="flex flex-wrap gap-1.5">
            {ESTADO_FILTROS.map((e) => {
              const activo = filtros.estado === e;
              return (
                <button
                  key={e}
                  type="button"
                  aria-pressed={activo}
                  onClick={() => cambiar({ estado: e })}
                  className={cn(
                    "min-h-9 rounded-full border px-3.5 text-sm tabular-nums transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring",
                    activo ? "border-foreground bg-foreground font-semibold text-background" : "border-border bg-card font-medium text-foreground hover:bg-muted/50",
                  )}
                >
                  {t(`estados.${e}`)}
                  {counts ? ` · ${formatNumber(counts[e])}` : ""}
                </button>
              );
            })}
          </div>
        </div>

        {historialError ? (
          <div role="alert" className="flex flex-col items-center gap-2 rounded-xl border border-border bg-card tarjeta-elevada p-6">
            <p className="text-sm text-destructive">{historialError.missing ? t("errorHistorialFalta") : t("error", { msg: historialError.msg })}</p>
            <Button variant="outline" size="sm" onClick={() => void loadHistorial(filtros, pagina, porPagina)}>
              {t("retry")}
            </Button>
          </div>
        ) : historial.length === 0 ? (
          cargando ? (
            <div className="flex h-32 items-center justify-center">
              <Loader2 className="h-5 w-5 animate-spin text-primary" />
            </div>
          ) : (
            <EmptyState icon={BarChart3} title={t("tabla.vacio")} />
          )
        ) : (
          <div className={cn("min-w-0 overflow-x-auto rounded-xl border border-border bg-card tarjeta-elevada", cargando && "opacity-60")}>
            <Table className="min-w-[820px]">
              <TableHeader className="bg-muted/50">
                <TableRow className="hover:bg-transparent">
                  <TableHead>{t("tabla.hora")}</TableHead>
                  <TableHead>{t("tabla.cliente")}</TableHead>
                  <TableHead>{t("tabla.servicio")}</TableHead>
                  <TableHead className="text-right">{t("tabla.monto")}</TableHead>
                  <TableHead>{t("tabla.destino")}</TableHead>
                  <TableHead>{t("tabla.status")}</TableHead>
                  <TableHead>
                    <span className="sr-only">{t("tabla.acciones")}</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {historial.map((f, i) => (
                  <TableRow key={`${f.operation_id}-${i}`}>
                    <TableCell className="whitespace-nowrap text-muted-foreground tabular-nums">
                      {formatOperacionHora(f.operacion_at, unDia)}
                    </TableCell>
                    <TableCell>
                      <span className="font-semibold">{f.cliente}</span>
                      <br />
                      <span className="text-xs text-muted-foreground">{f.telefono}</span>
                    </TableCell>
                    <TableCell className="capitalize">
                      <ServiceDot service={f.servicio ?? f.service_type} />
                      {serviceNameEs(f.servicio ?? f.service_type) ?? (f.servicio ?? f.service_type)}
                    </TableCell>
                    <TableCell className="text-right font-medium tabular-nums">{fmtGyd(f.monto_gyd)}</TableCell>
                    <TableCell>{historialDestino(f)}</TableCell>
                    <TableCell>
                      <StatusPill status={f.status} label={statusLabel(f.status)} />
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      <div className="flex items-center gap-2">
                        <button
                          type="button"
                          aria-label={t("copiarId", { id: f.operation_id })}
                          title={t("copiarId", { id: f.operation_id })}
                          onClick={() => void copiarId(f.operation_id)}
                          className="inline-flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring"
                        >
                          {copiado === f.operation_id ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                        </button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        {total > 0 && (
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-border bg-card tarjeta-elevada px-3 py-2">
            <p className="text-xs text-muted-foreground">{PAG_TXT.mostrando(primeraFila, ultimaFila, total)}</p>
            <div className="flex flex-wrap items-center gap-2">
              <Select
                value={String(porPagina)}
                onValueChange={(v) => {
                  setPorPagina(Number(v));
                  setPagina(0);
                }}
              >
                <SelectTrigger className="w-24" aria-label={PAG_TXT.porPagina}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {TAMANOS_PAGINA.map((n) => (
                    <SelectItem key={n} value={String(n)}>
                      {n}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Button size="sm" variant="outline" disabled={pagina === 0 || cargando} onClick={() => setPagina((p) => Math.max(p - 1, 0))}>
                {PAG_TXT.anterior}
              </Button>
              <Button size="sm" variant="outline" disabled={!haySiguiente || cargando} onClick={() => setPagina((p) => p + 1)}>
                {PAG_TXT.siguiente}
              </Button>
            </div>
          </div>
        )}
      </section>

      <div className="flex items-center gap-2 text-xs text-muted-foreground/60">
        <BarChart3 className="h-3.5 w-3.5" />
        Remesas YA
      </div>
    </div>
  );
}
