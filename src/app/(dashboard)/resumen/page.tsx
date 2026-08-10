"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { useTranslations } from "next-intl";
import { format } from "date-fns";
import { BarChart3, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
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
  beneficiario: string;
  /** Ya viene enmascarada (9205****9412) a propósito. */
  tarjeta: string;
  operation_id: string;
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

const SERVICIOS = [
  "remesa",
  "combo",
  "recarga",
  "visa",
  "traduccion",
  "mexico",
] as const;

const SERVICIO_LABEL: Record<string, string> = {
  remesa: "Remesa",
  combo: "Combo",
  recarga: "Recarga",
  visa: "Visa",
  traduccion: "Traducción",
  mexico: "México",
};

function fmtGyd(n: number | null | undefined): string {
  return `${(n ?? 0).toLocaleString("en-US")} GYD`;
}

export default function ResumenPage() {
  const t = useTranslations("Resumen.page");
  const [resumen, setResumen] = useState<ResumenPeriodo[] | null>(null);
  const [historial, setHistorial] = useState<HistorialFila[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [servicio, setServicio] = useState("");
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");

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
    async (svc: string, dsd: string, hst: string) => {
      try {
        const supabase = createClient();
        const { data, error: rpcErr } = await supabase.rpc(
          "cerebro_dashboard_historial",
          {
            p_desde: dsd || null,
            p_hasta: hst || null,
            p_servicio: svc || null,
            p_limite: 200,
          },
        );
        if (rpcErr) throw new Error(rpcErr.message);
        setHistorial((data ?? []) as HistorialFila[]);
      } catch (err) {
        console.error("[resumen] historial:", err);
        setError(err instanceof Error ? err.message : String(err));
      }
    },
    [],
  );

  useEffect(() => {
    void loadResumen();
    void loadHistorial("", "", "");
  }, [loadResumen, loadHistorial]);

  const aplicar = useCallback(() => {
    void loadHistorial(servicio, desde, hasta);
  }, [loadHistorial, servicio, desde, hasta]);

  if (error) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-2">
        <p className="text-sm text-destructive">{t("error", { msg: error })}</p>
        <Button variant="outline" onClick={() => window.location.reload()}>
          Retry
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
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">{t("title")}</h1>
        <p className="mt-1 text-sm text-muted-foreground">{t("subtitle")}</p>
      </div>

      {/* Resumen por periodo */}
      <section className="space-y-2">
        <h2 className="text-sm font-semibold text-foreground">
          {t("resumenTitle")}
        </h2>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
          {resumen.map((p) => {
            const labelKey = PERIODO_ORDEN[p.orden] ?? null;
            const label = labelKey ? t(`periodos.${labelKey}`) : p.periodo;
            return (
              <div
                key={p.orden}
                className="rounded-xl border border-border bg-card p-4"
              >
                <p className="text-xs font-medium text-muted-foreground">
                  {label}
                </p>
                <p className="mt-2 text-2xl font-bold text-foreground">
                  {p.operaciones}
                </p>
                <p className="mt-1 text-xs text-muted-foreground">
                  {t("operaciones")}
                </p>
                <p className="mt-2 text-sm font-semibold text-foreground">
                  {fmtGyd(p.volumen_gyd)}
                </p>
                <p className="mt-0.5 text-[11px] text-muted-foreground/70">
                  {t("ticketMedio")}: {fmtGyd(p.ticket_medio_gyd)}
                </p>
              </div>
            );
          })}
        </div>
        <p className="text-[11px] text-muted-foreground/70">{t("noteDesde")}</p>
      </section>

      {/* Historial */}
      <section className="space-y-3">
        <h2 className="text-sm font-semibold text-foreground">
          {t("historialTitle")}
        </h2>
        <div className="flex flex-wrap items-end gap-3">
          <label className="space-y-1">
            <span className="text-xs text-muted-foreground">
              {t("filtros.servicio")}
            </span>
            <select
              value={servicio}
              onChange={(e) => setServicio(e.target.value)}
              className="h-9 rounded-md border border-border bg-background px-2 text-sm"
            >
              <option value="">{t("filtros.todos")}</option>
              {SERVICIOS.map((s) => (
                <option key={s} value={s}>
                  {SERVICIO_LABEL[s]}
                </option>
              ))}
            </select>
          </label>
          <label className="space-y-1">
            <span className="text-xs text-muted-foreground">
              {t("filtros.desde")}
            </span>
            <input
              type="date"
              value={desde}
              onChange={(e) => setDesde(e.target.value)}
              className="h-9 rounded-md border border-border bg-background px-2 text-sm"
            />
          </label>
          <label className="space-y-1">
            <span className="text-xs text-muted-foreground">
              {t("filtros.hasta")}
            </span>
            <input
              type="date"
              value={hasta}
              onChange={(e) => setHasta(e.target.value)}
              className="h-9 rounded-md border border-border bg-background px-2 text-sm"
            />
          </label>
          <Button size="sm" onClick={aplicar}>
            {t("filtros.aplicar")}
          </Button>
        </div>

        {historial.length === 0 ? (
          <div className="flex h-32 items-center justify-center rounded-xl border border-dashed border-border bg-muted/40">
            <p className="text-sm text-muted-foreground">
              {t("tabla.vacio")}
            </p>
          </div>
        ) : (
          <div className="overflow-x-auto rounded-xl border border-border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t("tabla.dia")}</TableHead>
                  <TableHead>{t("tabla.servicio")}</TableHead>
                  <TableHead>{t("tabla.status")}</TableHead>
                  <TableHead>{t("tabla.cliente")}</TableHead>
                  <TableHead>{t("tabla.telefono")}</TableHead>
                  <TableHead>{t("tabla.monto")}</TableHead>
                  <TableHead>{t("tabla.beneficiario")}</TableHead>
                  <TableHead>{t("tabla.tarjeta")}</TableHead>
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
                      {SERVICIO_LABEL[f.service_type] ?? f.service_type}
                    </TableCell>
                    <TableCell className="capitalize">{f.status}</TableCell>
                    <TableCell>{f.cliente}</TableCell>
                    <TableCell>{f.telefono}</TableCell>
                    <TableCell className="font-medium">
                      {fmtGyd(f.monto_gyd)}
                    </TableCell>
                    <TableCell>{f.beneficiario}</TableCell>
                    <TableCell>{f.tarjeta}</TableCell>
                    <TableCell className="font-mono text-xs">
                      {f.operation_id}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
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
