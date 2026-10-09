"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { useTranslations } from "next-intl";
import { format } from "date-fns";
import { BarChart3, Loader2 } from "lucide-react";
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
import { PageHeader, PageShell } from "@/components/layout/page-header";
import { FinancialCloseSection } from "@/components/resumen/financial-close-section";
import { StatusPill } from "@/components/status/status-pill";
import { ServiceDot } from "@/components/service/service-dot";
import { MoneyTotalFigure } from "@/components/money/money-total-figure";
import { moneyStripeElevatedClass } from "@/lib/money-tone";
import { formatNumber } from "@/lib/format-number";
import { historialDestino } from "@/lib/resumen/historial-destino";
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

interface HistorialFila {
  dia: string;
  service_type: string;
  status: string;
  cliente: string;
  telefono: string;
  monto_gyd: number;
  /** Solo remesas: null en recargas y demás servicios. */
  beneficiario: string | null;
  /** Ya viene enmascarada (9205****9412) a propósito. Null sin tarjeta. */
  tarjeta: string | null;
  operation_id: string;
  /** Filas que hay en TODO el filtro, no en esta página (088). */
  total: number;
  /** Servicio de la operación en el vocabulario del libro (CUP, ZELLE, MIXTA…), desde la 229. Ausente en una base sin ella. */
  servicio?: string | null;
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

export default function ResumenPage() {
  const t = useTranslations("Resumen.page");
  const tStatus = useTranslations("Inbox.operationsPanel.status");
  const [resumen, setResumen] = useState<ResumenPeriodo[] | null>(null);
  const [historial, setHistorial] = useState<HistorialFila[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [servicio, setServicio] = useState("");
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [pagina, setPagina] = useState(0);
  const [porPagina, setPorPagina] = useState<number>(TAMANOS_PAGINA[0]);
  const [total, setTotal] = useState(0);
  const [cargando, setCargando] = useState(false);

  const loadResumen = useCallback(async () => {
    try {
      const supabase = createClient();
      const { data, error: rpcErr } = await supabase.rpc(
        "cerebro_dashboard_resumen",
      );
      if (rpcErr) throw new Error(rpcErr.message);
      setResumen((data ?? []) as ResumenPeriodo[]);
    } catch (err) {
      console.error("[resumen]", err);
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  const loadHistorial = useCallback(
    async (svc: string, dsd: string, hst: string, pag: number, tam: number) => {
      setCargando(true);
      try {
        const supabase = createClient();
        const { data, error: rpcErr } = await supabase.rpc(
          "cerebro_dashboard_historial",
          {
            p_desde: dsd || null,
            p_hasta: hst || null,
            p_servicio: svc || null,
            p_limite: tam,
            p_desde_fila: pag * tam,
          },
        );
        if (rpcErr) throw new Error(rpcErr.message);
        const filas = (data ?? []) as HistorialFila[];
        setHistorial(filas);
        // `total` viene repetido en cada fila; sin filas, no hay nada.
        setTotal(filas[0]?.total ?? 0);
      } catch (err) {
        console.error("[resumen] historial:", err);
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setCargando(false);
      }
    },
    [],
  );

  useEffect(() => {
    void loadResumen();
  }, [loadResumen]);

  // Una sola puerta de entrada al historial: cualquier cambio de página o
  // de tamaño recarga por aquí. Los filtros NO están en las dependencias
  // a propósito — solo entran cuando se pulsa Aplicar.
  useEffect(() => {
    void loadHistorial(servicio, desde, hasta, pagina, porPagina);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loadHistorial, pagina, porPagina]);

  const aplicar = useCallback(() => {
    // Volver a la primera página: quedarse en la 4 con un filtro nuevo
    // que devuelve 12 filas dejaría la tabla vacía sin explicación.
    if (pagina === 0) {
      void loadHistorial(servicio, desde, hasta, 0, porPagina);
    } else {
      setPagina(0);
    }
  }, [loadHistorial, servicio, desde, hasta, pagina, porPagina]);

  const primeraFila = total === 0 ? 0 : pagina * porPagina + 1;
  const ultimaFila = Math.min((pagina + 1) * porPagina, total);
  const haySiguiente = (pagina + 1) * porPagina < total;

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
    <PageShell>
      <PageHeader title={t("title")} description={t("subtitle")} />

      {/* Resumen por periodo */}
      <section data-testid="resumen-section" className="space-y-2">
        <h2 className="text-base font-semibold tracking-tight text-foreground">
          {t("resumenTitle")}
        </h2>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
          {resumen.map((p) => {
            const labelKey = PERIODO_ORDEN[p.orden] ?? null;
            const label = labelKey ? t(`periodos.${labelKey}`) : p.periodo;
            return (
              <div
                key={p.orden}
                data-testid="resumen-card"
                className={`rounded-xl border border-border bg-card p-4 ${moneyStripeElevatedClass.in}`}
              >
                <p className="text-xs font-medium text-muted-foreground">
                  {label}
                </p>
                <p className="mt-2 text-xl font-bold tabular-nums text-foreground">
                  <MoneyTotalFigure
                    kind="in"
                    value={p.volumen_gyd}
                    format={fmtGyd}
                  />
                </p>
                <p className="mt-2 text-sm font-semibold tabular-nums text-foreground">
                  {p.operaciones}{" "}
                  <span className="text-xs font-normal text-muted-foreground">
                    {t("operaciones")}
                  </span>
                </p>
                <p className="mt-0.5 text-[11px] tabular-nums text-muted-foreground">
                  {t("ticketMedio")}: {fmtGyd(p.ticket_medio_gyd)}
                </p>
              </div>
            );
          })}
        </div>
        <p className="text-[11px] text-muted-foreground/70">{t("noteDesde")}</p>
      </section>

      {/* Cierre financiero: lo facturado/invertido/ganado segun el libro de
          la calculadora (121). Va despues del resumen; el historial debajo. */}
      <FinancialCloseSection />

      {/* Historial */}
      <section data-testid="historial-section" className="space-y-3">
        <h2 className="text-base font-semibold tracking-tight text-foreground">
          {t("historialTitle")}
        </h2>
        {/* Los cuatro controles eran <select>/<input> nativos sin estilar,
            y cada <label> llevaba `space-y-1` sobre un elemento inline —
            que no separa nada: la etiqueta acababa pegada al control, en
            la misma linea. Ahora son los mismos primitivos que usa el
            resto de la app, con la etiqueta encima. */}
        <div className="flex flex-wrap items-end gap-3 rounded-xl border border-border bg-card tarjeta-elevada p-3">
          <Field label={t("filtros.servicio")}>
            <Select
              value={servicio || TODOS}
              onValueChange={(v) => setServicio(!v || v === TODOS ? "" : v)}
            >
              <SelectTrigger className="w-40">
                {/* Base UI pinta el valor en crudo si no le das la etiqueta,
                    asi que el centinela saldria literal ("__todos__"). */}
                <SelectValue>
                  {(v) =>
                    v === TODOS || !v
                      ? t("filtros.todos")
                      : (serviceNameEs(v as string) ?? (v as string))
                  }
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
            <Input
              type="date"
              value={desde}
              onChange={(e) => setDesde(e.target.value)}
              className="w-40"
            />
          </Field>
          <Field label={t("filtros.hasta")}>
            <Input
              type="date"
              value={hasta}
              onChange={(e) => setHasta(e.target.value)}
              className="w-40"
            />
          </Field>
          <Button size="sm" onClick={aplicar} disabled={cargando}>
            {cargando ? t("filtros.cargando") : t("filtros.aplicar")}
          </Button>
          {/* El tamano de pagina no filtra nada: es un control de la tabla.
              `ml-auto` lo separa del grupo de filtros en vez de dejarlo
              como si fuera un cuarto criterio de busqueda. */}
          <Field label={PAG_TXT.porPagina} className="ml-auto">
            <Select
              value={String(porPagina)}
              onValueChange={(v) => {
                setPorPagina(Number(v));
                setPagina(0);
              }}
            >
              <SelectTrigger className="w-24">
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
          </Field>
        </div>

        {historial.length === 0 ? (
          <EmptyState icon={BarChart3} title={t("tabla.vacio")} />
        ) : (
          <div
            className={`overflow-x-auto rounded-xl border border-border bg-card tarjeta-elevada ${
              cargando ? "opacity-60" : ""
            }`}
          >
            <Table>
              <TableHeader className="bg-muted/50">
                <TableRow className="hover:bg-transparent">
                  <TableHead>{t("tabla.dia")}</TableHead>
                  <TableHead>{t("tabla.servicio")}</TableHead>
                  <TableHead>{t("tabla.status")}</TableHead>
                  <TableHead>{t("tabla.cliente")}</TableHead>
                  <TableHead>{t("tabla.telefono")}</TableHead>
                  <TableHead className="text-right">{t("tabla.monto")}</TableHead>
                  <TableHead>{t("tabla.destino")}</TableHead>
                  <TableHead>{t("tabla.operation")}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {historial.map((f, i) => (
                  <TableRow key={`${f.operation_id}-${i}`}>
                    <TableCell>
                      {format(new Date(`${f.dia}T00:00:00`), "dd/MM/yy")}
                    </TableCell>
                    <TableCell className="capitalize">
                      <ServiceDot service={f.servicio ?? f.service_type} />
                      {serviceNameEs(f.servicio ?? f.service_type) ?? (f.servicio ?? f.service_type)}
                    </TableCell>
                    <TableCell>
                      <StatusPill
                        status={f.status}
                        label={tStatus.has(f.status) ? tStatus(f.status) : f.status}
                      />
                    </TableCell>
                    <TableCell>{f.cliente}</TableCell>
                    <TableCell>{f.telefono}</TableCell>
                    <TableCell className="text-right font-medium tabular-nums">
                      {fmtGyd(f.monto_gyd)}
                    </TableCell>
                    <TableCell>{historialDestino(f)}</TableCell>
                    <TableCell className="font-mono text-xs">
                      {f.operation_id}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        {total > 0 && (
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-border bg-card tarjeta-elevada px-3 py-2">
            <p className="text-xs text-muted-foreground">
              {PAG_TXT.mostrando(primeraFila, ultimaFila, total)}
            </p>
            <div className="flex items-center gap-2">
              <Button
                size="sm"
                variant="outline"
                disabled={pagina === 0 || cargando}
                onClick={() => setPagina((p) => Math.max(p - 1, 0))}
              >
                {PAG_TXT.anterior}
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={!haySiguiente || cargando}
                onClick={() => setPagina((p) => p + 1)}
              >
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
    </PageShell>
  );
}
